`timescale 1ns/100ps
// ============================================================================
// VGA 640×480 @ 60Hz Timing Controller
// ============================================================================
// Generates standard VGA sync signals from a 25 MHz pixel clock.
// Provides current pixel (x, y) and an active-region flag.
//
// Timing (pixels):
//   Horizontal: 640 visible + 16 front porch + 96 sync + 48 back porch = 800
//   Vertical:   480 visible + 10 front porch +  2 sync + 33 back porch = 525
//   Pixel clock: 25.175 MHz (we use 25 MHz from CLOCK_50/2)
// ============================================================================

module vga_controller (
    input  logic        clk_25,      // 25 MHz pixel clock
    input  logic        rst_n,

    output logic [9:0]  vga_x,       // current pixel column (0-799)
    output logic [9:0]  vga_y,       // current pixel row (0-524)
    output logic        active,      // high when in visible area
    output logic        hsync,       // active-low horizontal sync
    output logic        vsync        // active-low vertical sync
);

    // Horizontal timing constants
    localparam H_VISIBLE = 640;
    localparam H_FRONT   = 16;
    localparam H_SYNC    = 96;
    localparam H_BACK    = 48;
    localparam H_TOTAL   = 800;

    // Vertical timing constants
    localparam V_VISIBLE = 480;
    localparam V_FRONT   = 10;
    localparam V_SYNC    = 2;
    localparam V_BACK    = 33;
    localparam V_TOTAL   = 525;

    // Counters
    logic [9:0] h_count;
    logic [9:0] v_count;

    always_ff @(posedge clk_25 or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= 0;
            v_count <= 0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= 0;
                if (v_count == V_TOTAL - 1)
                    v_count <= 0;
                else
                    v_count <= v_count + 1;
            end else begin
                h_count <= h_count + 1;
            end
        end
    end

    // Sync signals (active-low)
    assign hsync = ~((h_count >= H_VISIBLE + H_FRONT) &&
                     (h_count <  H_VISIBLE + H_FRONT + H_SYNC));
    assign vsync = ~((v_count >= V_VISIBLE + V_FRONT) &&
                     (v_count <  V_VISIBLE + V_FRONT + V_SYNC));

    // Active video region
    assign active = (h_count < H_VISIBLE) && (v_count < V_VISIBLE);

    // Pixel coordinates
    assign vga_x = h_count;
    assign vga_y = v_count;

endmodule
