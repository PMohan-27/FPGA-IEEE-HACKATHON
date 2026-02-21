`timescale 1ns/100ps
// ============================================================================
// Dual-Port Framebuffer — 320×240 × 8-bit (RGB332)
// ============================================================================
// Port A: Write port (ray tracer writes rendered pixels)
// Port B: Read port  (VGA controller reads for display)
//
// Total: 320 × 240 = 76,800 bytes — fits in Cyclone V on-chip M10K blocks.
// The DE1-SoC has 553 M10K blocks × 10,240 bits = ~690 KB available.
// This framebuffer uses 76,800 bytes = ~75 KB = ~60 M10K blocks (11%).
// ============================================================================

module framebuffer (
    // Write port (ray tracer domain)
    input  logic        wr_clk,
    input  logic        wr_en,
    input  logic [16:0] wr_addr,     // 0 to 76799
    input  logic [7:0]  wr_data,     // RGB332

    // Read port (VGA domain)
    input  logic        rd_clk,
    input  logic [16:0] rd_addr,
    output logic [7:0]  rd_data
);

    // Infer block RAM (dual-port)
    logic [7:0] mem [0:76799];

    // Initialize to black
    initial begin
        for (int i = 0; i < 76800; i++)
            mem[i] = 8'h00;
    end

    // Write port
    always_ff @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // Read port
    always_ff @(posedge rd_clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
