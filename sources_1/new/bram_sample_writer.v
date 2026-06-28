`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: bram_sample_writer
// Description:
//   Write 4-channel ADC samples from PL into the external BRAM port exported by
//   design_1_wrapper.
//
//   Input sample format from adc_sample4:
//       sample_data = {ch1, ch2, ch3, ch4}
//       sample_valid is one clk pulse when one 64-bit sample is valid.
//
//   BRAM format, 32-bit little-block words:
//       byte offset + 0: word0 = {ch2, ch1}
//       byte offset + 4: word1 = {ch4, ch3}
//
//   64 KB BRAM address map:
//       bank0: 0x0000 ~ 0x7FFF, 4096 samples
//       bank1: 0x8000 ~ 0xFFFF, 4096 samples
//
//   ps_control bit map, PS -> PL, from AXI GPIO output channel:
//       bit0: clear bank0_ready, rising-edge effective
//       bit1: clear bank1_ready, rising-edge effective
//       bit2: capture_enable, level effective
//       bit3: clear overflow, rising-edge effective
//       bit4: soft reset writer, rising-edge effective
//
//   pl_status bit map, PL -> PS, to AXI GPIO input channel:
//       bit0      : bank0_ready
//       bit1      : bank1_ready
//       bit2      : overflow
//       bit3      : active_bank
//       bit4      : writer_busy
//       bit5      : capture_enable
//       bit15:6   : reserved
//       bit31:16  : sample_idx in current active bank
//////////////////////////////////////////////////////////////////////////////////

module bram_sample_writer #(
    parameter integer BANK_SAMPLE_COUNT = 4096,
    parameter [31:0]  BANK0_BASE_ADDR   = 32'h0000_0000,
    parameter [31:0]  BANK1_BASE_ADDR   = 32'h0000_8000
)(
    input  wire        clk,

    input  wire        sample_valid,
    input  wire [63:0] sample_data,

    input  wire [31:0] ps_control,
    output wire [31:0] pl_status,

    output reg  [31:0] bram_addr = 32'd0,
    output wire        bram_clk,
    output reg  [31:0] bram_din  = 32'd0,
    input  wire [31:0] bram_dout,
    output reg         bram_en   = 1'b0,
    output wire        bram_rst,
    output reg  [3:0]  bram_we   = 4'b0000
);

    // The external BRAM port is written in the same clock domain as ADC sampling.
    assign bram_clk = clk;
    assign bram_rst = 1'b0;

    // bram_dout is not used by the PL writer. Tie it to a dummy wire so that
    // synthesis tools do not warn about accidental functional dependence.
    wire [31:0] unused_bram_dout = bram_dout;

    localparam [1:0]
        W_IDLE  = 2'd0,
        W_WORD1 = 2'd1,
        W_DONE  = 2'd2;

    reg [1:0]  write_state = W_IDLE;
    reg [63:0] sample_hold = 64'd0;
    reg [15:0] sample_idx  = 16'd0;

    reg bank0_ready = 1'b0;
    reg bank1_ready = 1'b0;
    reg overflow    = 1'b0;
    reg active_bank = 1'b0;

    reg [31:0] ps_control_d = 32'd0;
    reg        writing_bank  = 1'b0;

    wire capture_enable      = ps_control[2];
    wire writer_busy         = (write_state != W_IDLE);

    wire clear_bank0_ready   = ps_control[0] & ~ps_control_d[0];
    wire clear_bank1_ready   = ps_control[1] & ~ps_control_d[1];
    wire clear_overflow      = ps_control[3] & ~ps_control_d[3];
    wire soft_reset          = ps_control[4] & ~ps_control_d[4];

    wire active_bank_ready   = active_bank ? bank1_ready : bank0_ready;
    wire selected_bank       = (!active_bank_ready) ? active_bank :
                               (!bank0_ready)       ? 1'b0 :
                               (!bank1_ready)       ? 1'b1 : active_bank;
    wire selected_bank_ready = selected_bank ? bank1_ready : bank0_ready;
    wire has_free_bank       = !selected_bank_ready;

    wire [31:0] selected_bank_base = selected_bank ? BANK1_BASE_ADDR : BANK0_BASE_ADDR;
    wire [31:0] sample_byte_offset = {13'd0, sample_idx, 3'b000};  // sample_idx * 8 bytes
    wire [31:0] write_base_addr    = selected_bank_base + sample_byte_offset;

    // sample_data = {ch1, ch2, ch3, ch4}
    wire [15:0] in_ch1 = sample_data[63:48];
    wire [15:0] in_ch2 = sample_data[47:32];
    wire [15:0] in_ch3 = sample_data[31:16];
    wire [15:0] in_ch4 = sample_data[15:0];

    assign pl_status = {
        sample_idx,          // [31:16]
        10'd0,               // [15:6]
        capture_enable,      // [5]
        writer_busy,         // [4]
        active_bank,         // [3]
        overflow,            // [2]
        bank1_ready,         // [1]
        bank0_ready          // [0]
    };

    always @(posedge clk) begin
        ps_control_d <= ps_control;

        // BRAM write strobes are active for one clk cycle. The synchronous
        // Block Memory Generator samples them on the following clock edge.
        bram_en <= 1'b0;
        bram_we <= 4'b0000;

        if (soft_reset) begin
            write_state  <= W_IDLE;
            sample_hold  <= 64'd0;
            sample_idx   <= 16'd0;
            bank0_ready  <= 1'b0;
            bank1_ready  <= 1'b0;
            overflow     <= 1'b0;
            active_bank  <= 1'b0;
            writing_bank <= 1'b0;
            bram_addr    <= 32'd0;
            bram_din     <= 32'd0;
            bram_en      <= 1'b0;
            bram_we      <= 4'b0000;
        end else begin
            if (clear_bank0_ready) begin
                bank0_ready <= 1'b0;
            end

            if (clear_bank1_ready) begin
                bank1_ready <= 1'b0;
            end

            if (clear_overflow) begin
                overflow <= 1'b0;
            end

            // If the current active bank is already full and another bank has
            // been released by PS, move the active pointer to a free bank.
            if (write_state == W_IDLE && active_bank_ready) begin
                if (!bank0_ready) begin
                    active_bank <= 1'b0;
                end else if (!bank1_ready) begin
                    active_bank <= 1'b1;
                end
            end

            case (write_state)
                W_IDLE: begin
                    if (sample_valid && capture_enable) begin
                        if (has_free_bank) begin
                            sample_hold  <= sample_data;
                            writing_bank <= selected_bank;
                            active_bank  <= selected_bank;

                            // First 32-bit word: {ch2, ch1}
                            bram_addr <= write_base_addr;
                            bram_din  <= {in_ch2, in_ch1};
                            bram_en   <= 1'b1;
                            bram_we   <= 4'b1111;

                            write_state <= W_WORD1;
                        end else begin
                            // Both banks are still ready, so PS has not consumed
                            // either buffer quickly enough.
                            overflow <= 1'b1;
                        end
                    end
                end

                W_WORD1: begin
                    // Second 32-bit word: {ch4, ch3}
                    bram_addr <= (writing_bank ? BANK1_BASE_ADDR : BANK0_BASE_ADDR)
                               + {13'd0, sample_idx, 3'b000} + 32'd4;
                    bram_din  <= {sample_hold[15:0], sample_hold[31:16]};
                    bram_en   <= 1'b1;
                    bram_we   <= 4'b1111;

                    write_state <= W_DONE;
                end

                W_DONE: begin
                    if (sample_idx >= BANK_SAMPLE_COUNT - 1) begin
                        sample_idx <= 16'd0;

                        if (writing_bank == 1'b0) begin
                            bank0_ready <= 1'b1;
                            if (!bank1_ready) begin
                                active_bank <= 1'b1;
                            end
                        end else begin
                            bank1_ready <= 1'b1;
                            if (!bank0_ready) begin
                                active_bank <= 1'b0;
                            end
                        end
                    end else begin
                        sample_idx <= sample_idx + 1'b1;
                    end

                    write_state <= W_IDLE;
                end

                default: begin
                    write_state <= W_IDLE;
                end
            endcase
        end
    end

endmodule
