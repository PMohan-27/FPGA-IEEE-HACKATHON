// ============================================================================
// DE1-SoC Wrapper — Ray-Sphere Intersection Engine with VGA Output
// ============================================================================
//
// DEMO:
//   - Press KEY[0] to render a frame (or auto-renders continuously)
//   - SW[1:0] selects scene (0-3):
//       0 = single red sphere
//       1 = two spheres (red + green)
//       2 = four colored spheres
//       3 = large centered yellow sphere
//   - SW[9] = continuous render mode (auto-restart after each frame)
//   - HEX displays show frame time in milliseconds
//   - LEDR[0] = busy (rendering), LEDR[9] = frame done pulse
//   - VGA output: 640×480 (320×240 doubled), black background, colored spheres
//
// ============================================================================

`timescale 1ns/100ps

module de1soc_wrapper (
    input         CLOCK_50,
    input  [9:0]  SW,
    input  [3:0]  KEY,
    inout         PS2_CLK,
    inout         PS2_DAT,
    output [6:0]  HEX5,
    output [6:0]  HEX4,
    output [6:0]  HEX3,
    output [6:0]  HEX2,
    output [6:0]  HEX1,
    output [6:0]  HEX0,
    output [9:0]  LEDR,
    output [7:0]  VGA_R,
    output [7:0]  VGA_G,
    output [7:0]  VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_BLANK_N,
    output        VGA_SYNC_N,
    output        VGA_CLK
);

    // ================================================================
    // Clock & Reset
    // ================================================================
    wire clk_50 = CLOCK_50;
    wire rst_n  = KEY[3];       // KEY[3] as active-low reset

    // Generate 25 MHz pixel clock by dividing 50 MHz by 2
    logic clk_25;
    always_ff @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n)
            clk_25 <= 0;
        else
            clk_25 <= ~clk_25;
    end

    // ================================================================
    // Q10.6 fixed-point helper
    // ================================================================
    function automatic logic signed [15:0] q(input int val);
        return 16'(val * 64);
    endfunction

    // ================================================================
    // Scene definitions — selected by SW[1:0]
    // ================================================================
    logic [1:0]         num_spheres_m1;
    logic signed [15:0] sph_cx  [4];
    logic signed [15:0] sph_cy  [4];
    logic signed [15:0] sph_cz  [4];
    logic signed [15:0] sph_r2  [4];
    logic        [7:0]  sph_rgb [4];
    logic signed [15:0] cam_z;

    always_comb begin
        // Defaults — clear all
        for (int i = 0; i < 4; i++) begin
            sph_cx[i]  = 16'sd0;
            sph_cy[i]  = 16'sd0;
            sph_cz[i]  = 16'sd0;
            sph_r2[i]  = 16'sd0;
            sph_rgb[i] = 8'h00;
        end
        num_spheres_m1 = 2'd0;
        cam_z = q(-10);

        case (SW[1:0])
            2'd0: begin
                // Scene 0: Single red sphere centered
                num_spheres_m1 = 2'd0;
                sph_cx[0] = q(0);  sph_cy[0] = q(0);  sph_cz[0] = q(5);
                sph_r2[0] = q(9);  sph_rgb[0] = 8'hE0; // red
            end

            2'd1: begin
                // Scene 1: Two spheres — red left, green right
                num_spheres_m1 = 2'd1;
                sph_cx[0] = q(-5); sph_cy[0] = q(0);  sph_cz[0] = q(8);
                sph_r2[0] = q(9);  sph_rgb[0] = 8'hE0; // red
                sph_cx[1] = q(5);  sph_cy[1] = q(0);  sph_cz[1] = q(8);
                sph_r2[1] = q(9);  sph_rgb[1] = 8'h1C; // green
            end

            2'd2: begin
                // Scene 2: Four spheres — corners + center
                num_spheres_m1 = 2'd3;
                sph_cx[0] = q(-6); sph_cy[0] = q(4);  sph_cz[0] = q(10);
                sph_r2[0] = q(9);  sph_rgb[0] = 8'hE0; // red TL
                sph_cx[1] = q(6);  sph_cy[1] = q(4);  sph_cz[1] = q(10);
                sph_r2[1] = q(9);  sph_rgb[1] = 8'h1C; // green TR
                sph_cx[2] = q(-6); sph_cy[2] = q(-4); sph_cz[2] = q(10);
                sph_r2[2] = q(9);  sph_rgb[2] = 8'h03; // blue BL
                sph_cx[3] = q(0);  sph_cy[3] = q(0);  sph_cz[3] = q(6);
                sph_r2[3] = q(16); sph_rgb[3] = 8'hFC; // yellow center
            end

            2'd3: begin
                // Scene 3: Single large yellow sphere (close-up)
                num_spheres_m1 = 2'd0;
                sph_cx[0] = q(0);  sph_cy[0] = q(0);  sph_cz[0] = q(4);
                sph_r2[0] = q(16); sph_rgb[0] = 8'hFC; // yellow
            end
        endcase
    end

    // ================================================================
    // Ray-Sphere Engine
    // ================================================================
    logic        rt_start, rt_busy, rt_frame_done;
    logic [9:0]  rt_x;
    logic [8:0]  rt_y;
    logic [7:0]  rt_color;
    logic        rt_valid;

    ray_sphere_top #(
        .SCREEN_W(320),
        .SCREEN_H(240),
        .MAX_SPHERES(4),
        .FRAC_BITS(6)
    ) ray_engine (
        .clk            (clk_50),
        .rst_n          (rst_n),
        .start          (rt_start),
        .busy           (rt_busy),
        .frame_done     (rt_frame_done),
        .num_spheres_m1 (num_spheres_m1),
        .sph_cx         (sph_cx),
        .sph_cy         (sph_cy),
        .sph_cz         (sph_cz),
        .sph_r2         (sph_r2),
        .sph_rgb        (sph_rgb),
        .cam_z          (cam_z),
        .out_x          (rt_x),
        .out_y          (rt_y),
        .out_color      (rt_color),
        .out_valid      (rt_valid)
    );

    // Render trigger: KEY[0] press or continuous mode (SW[9])
    logic key0_prev;
    logic key0_edge;

    always_ff @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n)
            key0_prev <= 1;
        else
            key0_prev <= KEY[0];
    end
    assign key0_edge = key0_prev & ~KEY[0]; // falling edge (KEY active-low)

    always_ff @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n) begin
            rt_start <= 0;
        end else begin
            rt_start <= 0;
            if (key0_edge && !rt_busy) begin
                rt_start <= 1;
            end
            // Continuous mode: auto-restart after frame done
            if (SW[9] && rt_frame_done && !rt_busy) begin
                rt_start <= 1;
            end
        end
    end

    // ================================================================
    // Framebuffer (320×240, 8-bit RGB332)
    // ================================================================
    wire [16:0] fb_wr_addr = {rt_y[7:0], 9'b0} + {rt_y[7:0], 6'b0} + {7'b0, rt_x};
    // = y * 320 + x = y*256 + y*64 + x

    wire        fb_wr_en = rt_valid;

    // VGA read side (addressed by VGA pixel / 2 for 2× scaling)
    logic [9:0] vga_x;
    logic [9:0] vga_y;
    logic       vga_active;

    wire [9:0]  fb_rx = vga_x >> 1;     // divide by 2 (640→320)
    wire [9:0]  fb_ry = vga_y >> 1;     // divide by 2 (480→240)
    wire [16:0] fb_rd_addr = {fb_ry[7:0], 9'b0} + {fb_ry[7:0], 6'b0} + {7'b0, fb_rx};

    logic [7:0] fb_rd_data;

    framebuffer fb_inst (
        .wr_clk  (clk_50),
        .wr_en   (fb_wr_en),
        .wr_addr (fb_wr_addr),
        .wr_data (rt_color),
        .rd_clk  (clk_25),
        .rd_addr (fb_rd_addr),
        .rd_data (fb_rd_data)
    );

    // ================================================================
    // VGA Controller
    // ================================================================
    logic vga_hsync, vga_vsync;

    vga_controller vga_ctrl (
        .clk_25  (clk_25),
        .rst_n   (rst_n),
        .vga_x   (vga_x),
        .vga_y   (vga_y),
        .active  (vga_active),
        .hsync   (vga_hsync),
        .vsync   (vga_vsync)
    );

    // ================================================================
    // VGA Output — expand RGB332 to RGB888
    // ================================================================
    // RGB332: [7:5]=R(3-bit), [4:2]=G(3-bit), [1:0]=B(2-bit)
    wire [7:0] r_expand = vga_active ? {fb_rd_data[7:5], fb_rd_data[7:5], fb_rd_data[7:6]} : 8'd0;
    wire [7:0] g_expand = vga_active ? {fb_rd_data[4:2], fb_rd_data[4:2], fb_rd_data[4:3]} : 8'd0;
    wire [7:0] b_expand = vga_active ? {fb_rd_data[1:0], fb_rd_data[1:0], fb_rd_data[1:0], fb_rd_data[1:0]} : 8'd0;

    assign VGA_R = r_expand;
    assign VGA_G = g_expand;
    assign VGA_B = b_expand;
    assign VGA_HS = vga_hsync;
    assign VGA_VS = vga_vsync;
    assign VGA_BLANK_N = vga_active;
    assign VGA_SYNC_N  = 1'b0;
    assign VGA_CLK     = clk_25;

    // ================================================================
    // HEX Display — show frame render time in cycles (or ms)
    // ================================================================
    logic [31:0] cycle_counter;
    logic [31:0] last_frame_cycles;

    always_ff @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter <= 0;
            last_frame_cycles <= 0;
        end else begin
            if (rt_start)
                cycle_counter <= 0;
            else if (rt_busy)
                cycle_counter <= cycle_counter + 1;

            if (rt_frame_done)
                last_frame_cycles <= cycle_counter;
        end
    end

    // Display last_frame_cycles / 50000 ≈ milliseconds on HEX[3:0]
    // Simple: just show raw cycle count / 1000 on HEX
    wire [15:0] frame_ms = last_frame_cycles[31:16]; // rough approx (/65536 ≈ /50000)

    // 7-segment decoder
    function automatic logic [6:0] hex_decode(input logic [3:0] val);
        case (val)
            4'h0: return 7'b1000000;
            4'h1: return 7'b1111001;
            4'h2: return 7'b0100100;
            4'h3: return 7'b0110000;
            4'h4: return 7'b0011001;
            4'h5: return 7'b0010010;
            4'h6: return 7'b0000010;
            4'h7: return 7'b1111000;
            4'h8: return 7'b0000000;
            4'h9: return 7'b0010000;
            4'hA: return 7'b0001000;
            4'hB: return 7'b0000011;
            4'hC: return 7'b1000110;
            4'hD: return 7'b0100001;
            4'hE: return 7'b0000110;
            4'hF: return 7'b0001110;
        endcase
    endfunction

    // Show cycle count in hex on HEX[5:0]
    assign HEX0 = hex_decode(last_frame_cycles[3:0]);
    assign HEX1 = hex_decode(last_frame_cycles[7:4]);
    assign HEX2 = hex_decode(last_frame_cycles[11:8]);
    assign HEX3 = hex_decode(last_frame_cycles[15:12]);
    assign HEX4 = hex_decode(last_frame_cycles[19:16]);
    assign HEX5 = hex_decode(last_frame_cycles[23:20]);

    // ================================================================
    // LEDs
    // ================================================================
    assign LEDR[0] = rt_busy;
    assign LEDR[9] = rt_frame_done;
    assign LEDR[8:1] = 8'b0;

endmodule
