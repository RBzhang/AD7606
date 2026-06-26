`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: testbench
// Description:
//   Testbench for the current AD7606/AD7606C parallel read controller.
//
//   This testbench is written according to the current top.v interface:
//   - top.v has no external rst_n port.
//   - ch1_data~ch4_data and data_valid are internal signals observed by ILA.
//   - Only adc_os is kept as a configuration output port in the current top.v.
//
//   Test points:
//   1. Check the resetless startup sequence and ADC reset pulse.
//   2. Model AD7606/AD7606C conversion behavior using CONVST/BUSY/RD/DB.
//   3. Verify that each CS-low read frame contains ADC_TOTAL_CH RD pulses.
//   4. Verify that V1~V4 read by the DUT match the generated ADC frame.
//   5. Verify that dut.data_valid is strictly periodic at SAMPLE_RATE_HZ.
//   6. Verify that dut.sample_overrun and dut.sample_underrun stay low.
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
    localparam integer ADC_CONV_TIME_NS  = 2_000;    // simulated ADC conversion time

    localparam integer RESET_CLKS        = 10;
    localparam integer CONVST_HIGH_CLKS  = 2;
    localparam integer RD_LOW_CLKS       = 2;
    localparam integer RD_HIGH_CLKS      = 2;

    localparam integer TEST_VALID_FRAMES = 12;
    localparam integer TIMEOUT_NS        = 250_000;

    // ============================================================
    // FPGA-side signals
    // ============================================================

    reg         clk;

    wire        adc_convst_a;
    wire        adc_convst_b;
    wire        adc_cs_n;
    wire        adc_rd_n;
    wire        adc_reset;
    wire [2:0]  adc_os;

    // ============================================================
    // ADC model signals
    // ============================================================

    reg         adc_busy;
    reg [15:0] adc_db;
    reg         adc_frstdata;

    reg [15:0] adc_frame [0:7];

    integer adc_sample_id;
    integer adc_read_idx;
    integer rd_count_in_cs;

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
    time this_valid_time;

    // ============================================================
    // Hierarchical DUT monitor signals
    // ============================================================
    // The current top.v keeps ch1_data~ch4_data and data_valid as internal
    // signals connected to ila_data. The testbench observes them through
    // hierarchical references.

    wire signed [15:0] dut_ch1_data   = dut.ch1_data;
    wire signed [15:0] dut_ch2_data   = dut.ch2_data;
    wire signed [15:0] dut_ch3_data   = dut.ch3_data;
    wire signed [15:0] dut_ch4_data   = dut.ch4_data;
    wire               dut_data_valid = dut.data_valid;

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
        .clk          (clk),

        .adc_busy     (adc_busy),
        .adc_db       (adc_db),
        .adc_frstdata (adc_frstdata),

        .adc_convst_a (adc_convst_a),
        .adc_convst_b (adc_convst_b),
        .adc_cs_n     (adc_cs_n),
        .adc_rd_n     (adc_rd_n),
        .adc_reset    (adc_reset),
        .adc_os       (adc_os)
    );

    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    // ============================================================
    // Initial values
    // ============================================================

    integer init_i;

    initial begin
        adc_busy      = 1'b0;
        adc_db        = 16'hzzzz;
        adc_frstdata  = 1'b0;

        for (init_i = 0; init_i < 8; init_i = init_i + 1) begin
            adc_frame[init_i] = 16'h0000;
        end

        adc_sample_id = 0;
        adc_read_idx  = 0;
        rd_count_in_cs = 0;

        exp_wr_ptr    = 0;
        exp_rd_ptr    = 0;
        valid_count   = 0;
        error_count   = 0;

        last_valid_time = 0;
        this_valid_time = 0;
    end

    // ============================================================
    // Startup and static configuration checks
    // ============================================================

    initial begin
        #1;

        if (adc_convst_a !== 1'b0) begin
            $display("ERROR: adc_convst_a initial value should be 0.");
            error_count = error_count + 1;
        end
        if (adc_convst_b !== 1'b0) begin
            $display("ERROR: adc_convst_b initial value should be 0.");
            error_count = error_count + 1;
        end
        if (adc_cs_n !== 1'b1) begin
            $display("ERROR: adc_cs_n initial value should be 1.");
            error_count = error_count + 1;
        end
        if (adc_rd_n !== 1'b1) begin
            $display("ERROR: adc_rd_n initial value should be 1.");
            error_count = error_count + 1;
        end
        if (adc_reset !== 1'b1) begin
            $display("ERROR: adc_reset should start from 1 to reset the ADC.");
            error_count = error_count + 1;
        end
        if (adc_os !== 3'b000) begin
            $display("ERROR: adc_os should be 000 when oversampling is disabled.");
            error_count = error_count + 1;
        end

        // adc_reset should be released after the internal S_RESET state.
        #(CLK_PERIOD_NS * (RESET_CLKS + 5));
        if (adc_reset !== 1'b0) begin
            $display("ERROR: adc_reset was not released after RESET_CLKS.");
            error_count = error_count + 1;
        end
    end

    // ============================================================
    // AD7606/AD7606C conversion model
    // ============================================================
    // CONVST rising edge is treated as the sampling instant.
    // Each frame uses a deterministic pattern:
    //   V1 = 16'h1000 + frame_id
    //   V2 = 16'h2000 + frame_id
    //   V3 = 16'h3000 + frame_id
    //   V4 = 16'h4000 + frame_id
    //   V5~V8 are also generated, then read and discarded by the DUT.

    always @(posedge adc_convst_a) begin
        if (adc_reset) begin
            $display("ERROR: CONVST occurred while adc_reset is high at %0t ns.", $time);
            error_count = error_count + 1;
        end

        if (adc_busy) begin
            $display("ERROR: CONVST occurred while ADC model is busy at %0t ns.", $time);
            error_count = error_count + 1;
        end

        adc_frame[0] = 16'h1000 + adc_sample_id[15:0];
        adc_frame[1] = 16'h2000 + adc_sample_id[15:0];
        adc_frame[2] = 16'h3000 + adc_sample_id[15:0];
        adc_frame[3] = 16'h4000 + adc_sample_id[15:0];
        adc_frame[4] = 16'h5000 + adc_sample_id[15:0];
        adc_frame[5] = 16'h6000 + adc_sample_id[15:0];
        adc_frame[6] = 16'h7000 + adc_sample_id[15:0];
        adc_frame[7] = 16'h8000 + adc_sample_id[15:0];

        exp_ch1[exp_wr_ptr] = adc_frame[0];
        exp_ch2[exp_wr_ptr] = adc_frame[1];
        exp_ch3[exp_wr_ptr] = adc_frame[2];
        exp_ch4[exp_wr_ptr] = adc_frame[3];

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
    // CS low enables the data bus. Each RD falling edge outputs the next
    // channel. FRSTDATA is asserted only for the first channel, but the DUT
    // currently reads channels by RD count rather than using FRSTDATA.

    always @(negedge adc_cs_n) begin
        adc_read_idx   = 0;
        rd_count_in_cs = 0;
        adc_frstdata   = 1'b0;
    end

    always @(posedge adc_cs_n) begin
        if (rd_count_in_cs != 0 && rd_count_in_cs != ADC_TOTAL_CH) begin
            $display("ERROR: CS frame ended with %0d RD pulses, expected %0d.",
                     rd_count_in_cs, ADC_TOTAL_CH);
            error_count = error_count + 1;
        end

        adc_read_idx   = 0;
        rd_count_in_cs = 0;
        adc_db         = 16'hzzzz;
        adc_frstdata   = 1'b0;
    end

    always @(negedge adc_rd_n) begin
        if (!adc_cs_n) begin
            if (adc_read_idx < 8) begin
                adc_db = adc_frame[adc_read_idx];
            end else begin
                adc_db = 16'hdead;
                $display("ERROR: More than 8 RD pulses in one ADC read frame at %0t ns.", $time);
                error_count = error_count + 1;
            end

            adc_frstdata   = (adc_read_idx == 0) ? 1'b1 : 1'b0;
            adc_read_idx   = adc_read_idx + 1;
            rd_count_in_cs = rd_count_in_cs + 1;
        end else begin
            $display("ERROR: RD falling edge occurred while CS is high at %0t ns.", $time);
            error_count = error_count + 1;
        end
    end

    always @(posedge adc_rd_n) begin
        adc_frstdata = 1'b0;
    end

    // ============================================================
    // CONVST pulse checks
    // ============================================================

    always @(posedge adc_convst_a or posedge adc_convst_b) begin
        if (adc_convst_a !== adc_convst_b) begin
            $display("ERROR: adc_convst_a and adc_convst_b are not aligned at %0t ns.", $time);
            error_count = error_count + 1;
        end
    end

    // ============================================================
    // Output checker
    // ============================================================
    // data_valid is internal in current top.v. It is checked through
    // dut.data_valid. Data is also read through dut.chx_data.

    always @(posedge dut_data_valid) begin
        this_valid_time = $time;

        $display("[%0t ns] DUT output: valid=%0d, ch1=%h, ch2=%h, ch3=%h, ch4=%h",
                 $time, valid_count,
                 dut_ch1_data, dut_ch2_data, dut_ch3_data, dut_ch4_data);

        if (valid_count > 0) begin
            if ((this_valid_time - last_valid_time) != SAMPLE_PERIOD_NS) begin
                $display("ERROR: data_valid period mismatch. expected=%0d ns, actual=%0t ns",
                         SAMPLE_PERIOD_NS, this_valid_time - last_valid_time);
                error_count = error_count + 1;
            end
        end
        last_valid_time = this_valid_time;

        if (exp_rd_ptr >= exp_wr_ptr) begin
            $display("ERROR: DUT produced data_valid before expected queue has data.");
            error_count = error_count + 1;
        end else begin
            if (dut_ch1_data !== exp_ch1[exp_rd_ptr]) begin
                $display("ERROR: ch1 mismatch. expected=%h, actual=%h", exp_ch1[exp_rd_ptr], dut_ch1_data);
                error_count = error_count + 1;
            end
            if (dut_ch2_data !== exp_ch2[exp_rd_ptr]) begin
                $display("ERROR: ch2 mismatch. expected=%h, actual=%h", exp_ch2[exp_rd_ptr], dut_ch2_data);
                error_count = error_count + 1;
            end
            if (dut_ch3_data !== exp_ch3[exp_rd_ptr]) begin
                $display("ERROR: ch3 mismatch. expected=%h, actual=%h", exp_ch3[exp_rd_ptr], dut_ch3_data);
                error_count = error_count + 1;
            end
            if (dut_ch4_data !== exp_ch4[exp_rd_ptr]) begin
                $display("ERROR: ch4 mismatch. expected=%h, actual=%h", exp_ch4[exp_rd_ptr], dut_ch4_data);
                error_count = error_count + 1;
            end
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

// ============================================================
// Optional ILA stub
// ============================================================
// Current top.v instantiates ila_data. In Vivado, the real ILA IP simulation
// model may already exist. If simulation reports that module ila_data is not
// found, enable this stub by defining TB_USE_ILA_STUB in simulation settings
// or by uncommenting `define TB_USE_ILA_STUB below.

// `define TB_USE_ILA_STUB

`ifdef TB_USE_ILA_STUB
module ila_data(
    input  wire        clk,
    input  wire [0:0]  probe0,
    input  wire [15:0] probe1,
    input  wire [15:0] probe2,
    input  wire [15:0] probe3,
    input  wire [15:0] probe4
);
endmodule
`endif
