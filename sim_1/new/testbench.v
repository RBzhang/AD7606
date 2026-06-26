`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/06/26 17:28:03
// Module Name: testbench
// Description:
//   Testbench for the AD7606/AD7606C parallel read controller.
//
//   Test points:
//   1. Generate a 50 MHz system clock and release reset.
//   2. Model an AD7606/AD7606C-like ADC:
//      - CONVST rising edge starts one conversion frame.
//      - BUSY stays high for a fixed conversion time.
//      - Parallel DB[15:0] outputs V1, V2, ... on each RD falling edge.
//   3. Check that top outputs ch1_data~ch4_data only when data_valid is high.
//   4. Check that data_valid pulses are strictly spaced by SAMPLE_RATE_HZ.
//   5. Check that ch1_data~ch4_data match the expected sampled frame.
//////////////////////////////////////////////////////////////////////////////////

module testbench();

    // ============================================================
    // Test parameters
    // ============================================================

    localparam integer SYS_CLK_HZ        = 50_000_000;
    localparam integer SAMPLE_RATE_HZ    = 100_000;
    localparam integer ADC_TOTAL_CH      = 8;

    localparam integer CLK_PERIOD_NS     = 20;
    localparam integer SAMPLE_PERIOD_NS  = 10_000;   // 100 kHz -> 10 us
    localparam integer ADC_CONV_TIME_NS  = 2_000;    // ADC BUSY high time for simulation

    localparam integer RESET_CLKS        = 10;
    localparam integer CONVST_HIGH_CLKS  = 2;
    localparam integer RD_LOW_CLKS       = 2;
    localparam integer RD_HIGH_CLKS      = 2;

    localparam integer TEST_VALID_FRAMES = 10;
    localparam integer TIMEOUT_NS        = 200_000;

    // ============================================================
    // FPGA-side signals
    // ============================================================

    reg         clk;
    reg         rst_n;

    wire        adc_convst_a;
    wire        adc_convst_b;
    wire        adc_cs_n;
    wire        adc_rd_n;
    wire        adc_reset;

    wire        adc_par_ser_byte_sel;
    wire [2:0]  adc_os;
    wire        adc_range;
    wire        adc_stby;
    wire        adc_ref_select;

    wire signed [15:0] ch1_data;
    wire signed [15:0] ch2_data;
    wire signed [15:0] ch3_data;
    wire signed [15:0] ch4_data;
    wire               data_valid;

    // ============================================================
    // ADC model signals
    // ============================================================

    reg         adc_busy;
    reg [15:0] adc_db;
    reg         adc_frstdata;

    reg [15:0] adc_frame_ch0;
    reg [15:0] adc_frame_ch1;
    reg [15:0] adc_frame_ch2;
    reg [15:0] adc_frame_ch3;
    reg [15:0] adc_frame_ch4;
    reg [15:0] adc_frame_ch5;
    reg [15:0] adc_frame_ch6;
    reg [15:0] adc_frame_ch7;

    integer adc_sample_id;
    integer adc_read_idx;

    // ============================================================
    // Expected output queue
    // ============================================================

    reg [15:0] exp_ch1 [0:255];
    reg [15:0] exp_ch2 [0:255];
    reg [15:0] exp_ch3 [0:255];
    reg [15:0] exp_ch4 [0:255];

    integer exp_wr_ptr;
    integer exp_rd_ptr;
    integer valid_count;
    integer error_count;

    time last_valid_time;

    // ============================================================
    // DUT
    // ============================================================

    top #(
        .SYS_CLK_HZ       (SYS_CLK_HZ),
        .SAMPLE_RATE_HZ   (SAMPLE_RATE_HZ),
        .ADC_TOTAL_CH     (ADC_TOTAL_CH),
        .RESET_CLKS       (RESET_CLKS),
        .CONVST_HIGH_CLKS (CONVST_HIGH_CLKS),
        .RD_LOW_CLKS      (RD_LOW_CLKS),
        .RD_HIGH_CLKS     (RD_HIGH_CLKS)
    ) dut (
        .clk                 (clk),
        .rst_n               (rst_n),

        .adc_busy            (adc_busy),
        .adc_db              (adc_db),
        .adc_frstdata        (adc_frstdata),

        .adc_convst_a        (adc_convst_a),
        .adc_convst_b        (adc_convst_b),
        .adc_cs_n            (adc_cs_n),
        .adc_rd_n            (adc_rd_n),
        .adc_reset           (adc_reset),

        .adc_par_ser_byte_sel(adc_par_ser_byte_sel),
        .adc_os              (adc_os),
        .adc_range           (adc_range),
        .adc_stby            (adc_stby),
        .adc_ref_select      (adc_ref_select),

        .ch1_data            (ch1_data),
        .ch2_data            (ch2_data),
        .ch3_data            (ch3_data),
        .ch4_data            (ch4_data),
        .data_valid          (data_valid)
    );

    // ============================================================
    // Clock and reset
    // ============================================================

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        #(CLK_PERIOD_NS * 20);
        rst_n = 1'b1;
    end

    // ============================================================
    // Initial values
    // ============================================================

    initial begin
        adc_busy      = 1'b0;
        adc_db        = 16'hzzzz;
        adc_frstdata  = 1'b0;

        adc_frame_ch0 = 16'h0000;
        adc_frame_ch1 = 16'h0000;
        adc_frame_ch2 = 16'h0000;
        adc_frame_ch3 = 16'h0000;
        adc_frame_ch4 = 16'h0000;
        adc_frame_ch5 = 16'h0000;
        adc_frame_ch6 = 16'h0000;
        adc_frame_ch7 = 16'h0000;

        adc_sample_id = 0;
        adc_read_idx  = 0;

        exp_wr_ptr    = 0;
        exp_rd_ptr    = 0;
        valid_count   = 0;
        error_count   = 0;

        last_valid_time = 0;
    end

    // ============================================================
    // AD7606/AD7606C conversion model
    // ============================================================
    // The DUT drives CONVST A/B together. Use CONVST A rising edge
    // as the sampling instant. Each conversion frame generates a simple
    // deterministic data pattern:
    //   V1 = 16'h1000 + frame_id
    //   V2 = 16'h2000 + frame_id
    //   V3 = 16'h3000 + frame_id
    //   V4 = 16'h4000 + frame_id
    //   V5~V8 are also provided to let the DUT read and discard them.

    always @(posedge adc_convst_a) begin
        adc_frame_ch0 = 16'h1000 + adc_sample_id[15:0];
        adc_frame_ch1 = 16'h2000 + adc_sample_id[15:0];
        adc_frame_ch2 = 16'h3000 + adc_sample_id[15:0];
        adc_frame_ch3 = 16'h4000 + adc_sample_id[15:0];
        adc_frame_ch4 = 16'h5000 + adc_sample_id[15:0];
        adc_frame_ch5 = 16'h6000 + adc_sample_id[15:0];
        adc_frame_ch6 = 16'h7000 + adc_sample_id[15:0];
        adc_frame_ch7 = 16'h8000 + adc_sample_id[15:0];

        exp_ch1[exp_wr_ptr] = 16'h1000 + adc_sample_id[15:0];
        exp_ch2[exp_wr_ptr] = 16'h2000 + adc_sample_id[15:0];
        exp_ch3[exp_wr_ptr] = 16'h3000 + adc_sample_id[15:0];
        exp_ch4[exp_wr_ptr] = 16'h4000 + adc_sample_id[15:0];

        $display("[%0t ns] ADC model: CONVST rising, frame_id=%0d", $time, adc_sample_id);

        adc_sample_id = adc_sample_id + 1;
        exp_wr_ptr    = exp_wr_ptr + 1;

        adc_busy <= 1'b1;
        #(ADC_CONV_TIME_NS);
        adc_busy <= 1'b0;
    end

    // ============================================================
    // AD7606/AD7606C parallel read model
    // ============================================================
    // Parallel mode sequence:
    //   CS low enables the output bus.
    //   Every RD falling edge outputs the next channel result.
    //   The DUT reads V1~V8 in order, but only keeps V1~V4.

    always @(negedge adc_cs_n) begin
        adc_read_idx = 0;
        adc_frstdata = 1'b0;
    end

    always @(posedge adc_cs_n) begin
        adc_read_idx = 0;
        adc_db       = 16'hzzzz;
        adc_frstdata = 1'b0;
    end

    always @(negedge adc_rd_n) begin
        if (!adc_cs_n) begin
            case (adc_read_idx)
                0: adc_db = adc_frame_ch0;
                1: adc_db = adc_frame_ch1;
                2: adc_db = adc_frame_ch2;
                3: adc_db = adc_frame_ch3;
                4: adc_db = adc_frame_ch4;
                5: adc_db = adc_frame_ch5;
                6: adc_db = adc_frame_ch6;
                7: adc_db = adc_frame_ch7;
                default: adc_db = 16'hdead;
            endcase

            adc_frstdata = (adc_read_idx == 0) ? 1'b1 : 1'b0;
            adc_read_idx = adc_read_idx + 1;
        end
    end

    always @(posedge adc_rd_n) begin
        adc_frstdata = 1'b0;
    end

    // ============================================================
    // Output checker
    // ============================================================

    always @(posedge clk) begin
        if (rst_n && data_valid) begin
            $display("[%0t ns] DUT output: valid=%0d, ch1=%h, ch2=%h, ch3=%h, ch4=%h",
                     $time, valid_count, ch1_data, ch2_data, ch3_data, ch4_data);

            if (valid_count > 0) begin
                if (($time - last_valid_time) != SAMPLE_PERIOD_NS) begin
                    $display("ERROR: data_valid period mismatch. expected=%0d ns, actual=%0t ns",
                             SAMPLE_PERIOD_NS, $time - last_valid_time);
                    error_count = error_count + 1;
                end
            end
            last_valid_time = $time;

            if (ch1_data !== exp_ch1[exp_rd_ptr]) begin
                $display("ERROR: ch1 mismatch. expected=%h, actual=%h", exp_ch1[exp_rd_ptr], ch1_data);
                error_count = error_count + 1;
            end
            if (ch2_data !== exp_ch2[exp_rd_ptr]) begin
                $display("ERROR: ch2 mismatch. expected=%h, actual=%h", exp_ch2[exp_rd_ptr], ch2_data);
                error_count = error_count + 1;
            end
            if (ch3_data !== exp_ch3[exp_rd_ptr]) begin
                $display("ERROR: ch3 mismatch. expected=%h, actual=%h", exp_ch3[exp_rd_ptr], ch3_data);
                error_count = error_count + 1;
            end
            if (ch4_data !== exp_ch4[exp_rd_ptr]) begin
                $display("ERROR: ch4 mismatch. expected=%h, actual=%h", exp_ch4[exp_rd_ptr], ch4_data);
                error_count = error_count + 1;
            end

            exp_rd_ptr  = exp_rd_ptr + 1;
            valid_count = valid_count + 1;

            if (valid_count == TEST_VALID_FRAMES) begin
                if (dut.sample_overrun) begin
                    $display("ERROR: dut.sample_overrun is asserted.");
                    error_count = error_count + 1;
                end
                if (dut.sample_underrun) begin
                    $display("ERROR: dut.sample_underrun is asserted.");
                    error_count = error_count + 1;
                end

                if (error_count == 0) begin
                    $display("============================================================");
                    $display("TEST PASSED: %0d valid frames checked successfully.", TEST_VALID_FRAMES);
                    $display("============================================================");
                end else begin
                    $display("============================================================");
                    $display("TEST FAILED: error_count=%0d", error_count);
                    $display("============================================================");
                end

                #100;
                $finish;
            end
        end
    end

    // ============================================================
    // Basic configuration checks
    // ============================================================

    initial begin
        wait(rst_n == 1'b1);
        #(CLK_PERIOD_NS * 5);

        if (adc_par_ser_byte_sel !== 1'b0) begin
            $display("ERROR: adc_par_ser_byte_sel should be 0 in parallel mode.");
            error_count = error_count + 1;
        end
        if (adc_os !== 3'b000) begin
            $display("ERROR: adc_os should be 000 when oversampling is disabled.");
            error_count = error_count + 1;
        end
        if (adc_stby !== 1'b1) begin
            $display("ERROR: adc_stby should be 1 in normal mode.");
            error_count = error_count + 1;
        end
    end

    // ============================================================
    // Timeout
    // ============================================================

    initial begin
        #(TIMEOUT_NS);
        $display("============================================================");
        $display("TEST TIMEOUT at %0t ns. valid_count=%0d, error_count=%0d", $time, valid_count, error_count);
        $display("============================================================");
        $finish;
    end

endmodule
