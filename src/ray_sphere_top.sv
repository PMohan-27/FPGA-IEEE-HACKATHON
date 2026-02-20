`timescale 1ns/100ps
// ============================================================================
// Ray-Sphere Intersection Engine — Pipelined Hardware Ray Tracer
// ============================================================================
//
// WHY HARDWARE BEATS A CPU:
//   The core intersection test requires 9 multiplications, 8 additions,
//   and 1 comparison. A CPU executes these sequentially (~30+ cycles with
//   memory/pipeline stalls). This design performs ALL 9 multiplies in
//   PARALLEL in a single clock, sustaining 1 intersection/cycle throughput.
//   At 50 MHz: 50M intersections/sec from a tiny FPGA.
//
// MATH (ray-sphere quadratic):
//   Ray: P(t) = O + t*D       Sphere: |P - C|² = r²
//   Let L = O - C, then solve: (D·D)t² + 2(L·D)t + (L·L - r²) = 0
//   discriminant = (L·D)² - (D·D)*(L·L - r²)
//   Hit if discriminant ≥ 0
//
// PIPELINE (3 stages, 1 result/clock after fill):
//   P1: L = O - C  (vector subtract)
//   P2: dot products: a=D·D, b=L·D, ll=L·L  (9 parallel multiplies)
//   P3: disc = b² - a*(ll - r²), hit = disc ≥ 0
//
// FIXED-POINT: Q10.6 signed (16-bit)
//   Range: [-512, +511.984375], Resolution: 1/64 = 0.015625
//
// FRAME: 320×240 pixels × up to 4 spheres = 307,200 tests
//   At 50 MHz ≈ 6.1 ms/frame ≈ 163 FPS
// ============================================================================

module ray_sphere_top #(
    parameter int SCREEN_W = 320,
    parameter int SCREEN_H = 240,
    parameter int MAX_SPHERES = 4,
    parameter int FRAC_BITS = 6          // Q10.6 format
)(
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        start,           // pulse high 1 cycle to begin frame
    output logic        busy,
    output logic        frame_done,      // pulses high 1 cycle when complete

    // Scene definition
    input  logic [1:0]  num_spheres_m1,  // 0 → 1 sphere, 3 → 4 spheres

    // Sphere data — Q10.6 signed fixed-point
    input  logic signed [15:0] sph_cx [MAX_SPHERES],
    input  logic signed [15:0] sph_cy [MAX_SPHERES],
    input  logic signed [15:0] sph_cz [MAX_SPHERES],
    input  logic signed [15:0] sph_r2 [MAX_SPHERES],  // r² pre-computed
    input  logic        [7:0]  sph_rgb [MAX_SPHERES],  // RGB332 color

    // Camera z-position (camera at origin x=0,y=0; looks along +Z)
    input  logic signed [15:0] cam_z,    // e.g. -1024 = -16.0 in Q10.6

    // Pixel output
    output logic [9:0]  out_x,
    output logic [8:0]  out_y,
    output logic [7:0]  out_color,       // RGB332 (0x00 = background/miss)
    output logic        out_valid        // high for exactly 1 cycle per pixel
);

    // =====================================================================
    // Fixed-point multiply: Q10.6 × Q10.6 → Q20.12 → shift right 6 → Q20.6
    // We keep the result as 32-bit to avoid overflow in accumulations.
    // =====================================================================
    function automatic logic signed [31:0] fp_mul(
        input logic signed [15:0] a,
        input logic signed [15:0] b
    );
        logic signed [31:0] full;
        full = $signed(a) * $signed(b);   // 32-bit product (Q20.12)
        return full >>> FRAC_BITS;         // → Q20.6 as 32-bit
    endfunction

    // =====================================================================
    // Scan state machine
    // =====================================================================
    typedef enum logic [1:0] { S_IDLE, S_SCAN, S_FLUSH, S_DONE } fsm_t;
    fsm_t fsm;

    logic [9:0] sx;   // scan pixel x
    logic [8:0] sy;   // scan pixel y
    logic [1:0] ss;   // scan sphere index
    logic       scan_active;

    wire last_sphere = (ss == num_spheres_m1);
    wire last_pixel  = (sx == SCREEN_W[9:0] - 1) && (sy == SCREEN_H[8:0] - 1);

    // =====================================================================
    // Ray direction for current pixel
    //   Screen center = (160, 120). 
    //   dir = (sx - 160, -(sy - 120), focal) — NOT shifted to Q10.6!
    //   
    //   The direction does NOT need Q10.6 encoding because it only appears
    //   in dot products with L (which IS Q10.6). The fp_mul handles the
    //   cross-format multiplication correctly since it just does (a*b)>>6.
    //   
    //   Focal length controls FOV: larger = narrower FOV = bigger spheres.
    //   At focal=160, a radius-3 sphere at distance 15 covers ~3357 pixels.
    // =====================================================================
    logic signed [15:0] dir_x, dir_y, dir_z;
    wire signed [15:0] sx_ext = {6'b0, sx};
    wire signed [15:0] sy_ext = {7'b0, sy};
    assign dir_x = sx_ext - 16'sd160;
    assign dir_y = -(sy_ext - 16'sd120);
    assign dir_z = 16'sd160;  // focal length (integer, not Q10.6)

    // =====================================================================
    // PIPELINE STAGE 1: L = O - C
    //   Camera at (0, 0, cam_z) in Q10.6
    // =====================================================================
    logic               p1v;
    logic signed [15:0] p1_lx, p1_ly, p1_lz;
    logic signed [15:0] p1_dx, p1_dy, p1_dz;
    logic signed [15:0] p1_r2;
    logic        [7:0]  p1_rgb;
    logic               p1_last;
    logic [9:0]         p1_x;
    logic [8:0]         p1_y;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1v <= 0;
        end else begin
            p1v <= scan_active;
            if (scan_active) begin
                p1_lx <= 16'sd0    - sph_cx[ss];
                p1_ly <= 16'sd0    - sph_cy[ss];
                p1_lz <= cam_z     - sph_cz[ss];
                p1_dx <= dir_x;
                p1_dy <= dir_y;
                p1_dz <= dir_z;
                p1_r2 <= sph_r2[ss];
                p1_rgb <= sph_rgb[ss];
                p1_last <= last_sphere;
                p1_x <= sx;
                p1_y <= sy;
            end
        end
    end

    // =====================================================================
    // PIPELINE STAGE 2: Dot products — 9 PARALLEL multipliers
    //   a  = D·D  = dx*dx + dy*dy + dz*dz
    //   b  = L·D  = lx*dx + ly*dy + lz*dz
    //   ll = L·L  = lx*lx + ly*ly + lz*lz
    //
    // >>>> THIS IS WHERE HARDWARE WINS <<<<
    // CPU: execute 9 multiplies + 6 adds SEQUENTIALLY (~15+ cycles)
    // FPGA: all 9 multiplies fire IN THE SAME CLOCK CYCLE
    // =====================================================================
    logic               p2v;
    logic signed [31:0] p2_a, p2_b, p2_ll;
    logic signed [15:0] p2_r2;
    logic        [7:0]  p2_rgb;
    logic               p2_last;
    logic [9:0]         p2_x;
    logic [8:0]         p2_y;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2v <= 0;
        end else begin
            p2v <= p1v;
            if (p1v) begin
                p2_a  <= fp_mul(p1_dx, p1_dx) + fp_mul(p1_dy, p1_dy) + fp_mul(p1_dz, p1_dz);
                p2_b  <= fp_mul(p1_lx, p1_dx) + fp_mul(p1_ly, p1_dy) + fp_mul(p1_lz, p1_dz);
                p2_ll <= fp_mul(p1_lx, p1_lx) + fp_mul(p1_ly, p1_ly) + fp_mul(p1_lz, p1_lz);
                p2_r2 <= p1_r2;
                p2_rgb <= p1_rgb;
                p2_last <= p1_last;
                p2_x  <= p1_x;
                p2_y  <= p1_y;
            end
        end
    end

    // =====================================================================
    // PIPELINE STAGE 3: Discriminant + hit test
    //   c    = ll - r²
    //   disc = b² - a * c
    //   hit  = (disc ≥ 0)
    // =====================================================================
    logic               p3v;
    logic               p3_hit;
    logic        [7:0]  p3_rgb;
    logic               p3_last;
    logic [9:0]         p3_x;
    logic [8:0]         p3_y;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p3v <= 0;
        end else begin
            p3v <= p2v;
            if (p2v) begin
                // sign-extend r² from 16 to 32 bits
                logic signed [31:0] c_val;
                logic signed [63:0] b_sq, a_c;
                logic disc_negative;

                c_val = p2_ll - $signed({{16{p2_r2[15]}}, p2_r2});
                b_sq  = $signed(p2_b) * $signed(p2_b);
                a_c   = $signed(p2_a) * $signed(c_val);

                // hit if discriminant (b²-ac) >= 0, i.e. sign bit is 0
                disc_negative = (b_sq - a_c) < 0;
                p3_hit  <= !disc_negative;
                p3_rgb  <= p2_rgb;
                p3_last <= p2_last;
                p3_x    <= p2_x;
                p3_y    <= p2_y;
            end
        end
    end

    // =====================================================================
    // Hit accumulator: track first hit for current pixel
    // When p3_last is set, emit the pixel and reset.
    // =====================================================================
    logic       acc_hit;
    logic [7:0] acc_rgb;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 0;
            out_color <= 0;
            out_x     <= 0;
            out_y     <= 0;
            acc_hit   <= 0;
            acc_rgb   <= 0;
        end else begin
            out_valid <= 0;  // default: no output

            if (p3v) begin
                // Update accumulator with this sphere's result
                if (p3_hit && !acc_hit) begin
                    acc_hit <= 1;
                    acc_rgb <= p3_rgb;
                end

                // Last sphere for this pixel → emit result
                if (p3_last) begin
                    out_valid <= 1;
                    out_x     <= p3_x;
                    out_y     <= p3_y;

                    if (p3_hit && !acc_hit) begin
                        // This last sphere is the first hit
                        out_color <= p3_rgb;
                    end else if (acc_hit) begin
                        // Earlier sphere already hit
                        out_color <= acc_rgb;
                    end else begin
                        // No sphere hit — background
                        out_color <= 8'h00;
                    end

                    // Reset for next pixel
                    acc_hit <= 0;
                    acc_rgb <= 0;
                end
            end
        end
    end

    // =====================================================================
    // FSM: controls scanning and pipeline flush
    // =====================================================================
    logic [2:0] flush_cnt;

    assign scan_active = (fsm == S_SCAN);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm        <= S_IDLE;
            sx         <= 0;
            sy         <= 0;
            ss         <= 0;
            busy       <= 0;
            frame_done <= 0;
            flush_cnt  <= 0;
        end else begin
            frame_done <= 0;

            case (fsm)
                S_IDLE: begin
                    if (start) begin
                        fsm  <= S_SCAN;
                        busy <= 1;
                        sx   <= 0;
                        sy   <= 0;
                        ss   <= 0;
                    end
                end

                S_SCAN: begin
                    if (!last_sphere) begin
                        ss <= ss + 2'd1;
                    end else begin
                        ss <= 0;
                        if (!last_pixel) begin
                            if (sx < SCREEN_W[9:0] - 1) begin
                                sx <= sx + 10'd1;
                            end else begin
                                sx <= 0;
                                sy <= sy + 9'd1;
                            end
                        end else begin
                            fsm       <= S_FLUSH;
                            flush_cnt <= 0;
                        end
                    end
                end

                S_FLUSH: begin
                    // Wait for 3-stage pipeline to drain
                    flush_cnt <= flush_cnt + 3'd1;
                    if (flush_cnt == 3'd5) begin
                        fsm <= S_DONE;
                    end
                end

                S_DONE: begin
                    frame_done <= 1;
                    busy       <= 0;
                    fsm        <= S_IDLE;
                end
            endcase
        end
    end

endmodule
