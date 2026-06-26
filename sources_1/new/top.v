`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/26 15:42:39
// Design Name: 
// Module Name: top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: AD7606/AD7606C parallel read controller.
//              The ADC channels are read sequentially, first stored in temporary
//              registers, and then updated to output registers in one clock cycle.
//              This guarantees ch1_data~ch4_data belong to the same sample frame.
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Add temporary channel registers for frame-synchronous output
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module top #(
    parameter integer SYS_CLK_HZ       = 50_000_000,
    parameter integer SAMPLE_RATE_HZ   = 100_000,   // AD7606C 可根据实际手册和时序进一步提高
    parameter integer ADC_TOTAL_CH     = 8,         // AD7606/AD7606C=8, AD7606-6=6, AD7606-4=4
    parameter integer RESET_CLKS       = 10,        // 50MHz 下 10clk = 200ns
    parameter integer CONVST_HIGH_CLKS = 2,         // 50MHz 下 2clk = 40ns
    parameter integer RD_LOW_CLKS      = 2,         // 50MHz 下 2clk = 40ns
    parameter integer RD_HIGH_CLKS     = 2          // 50MHz 下 2clk = 40ns
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================
    // AD7606/AD7606C -> FPGA
    // =========================
    input  wire        adc_busy,
    input  wire [15:0] adc_db,
    input  wire        adc_frstdata,

    // =========================
    // FPGA -> AD7606/AD7606C
    // =========================
    output reg         adc_convst_a,
    output reg         adc_convst_b,
    output reg         adc_cs_n,
    output reg         adc_rd_n,
    output reg         adc_reset,

    // 如果这些引脚由 FPGA 控制，可以这样输出；
    // 如果你的硬件已经固定接 GND/VCC，可以删掉这些端口。
    output wire        adc_par_ser_byte_sel,
    output wire [2:0]  adc_os,
    output wire        adc_range,
    output wire        adc_stby,
    output wire        adc_ref_select,

    // 只保留前四个通道。
    // 这四个输出只在一帧数据全部读完后同时更新。
    output reg signed [15:0] ch1_data,
    output reg signed [15:0] ch2_data,
    output reg signed [15:0] ch3_data,
    output reg signed [15:0] ch4_data,
    output reg               data_valid
);

    // ============================================================
    // 固定配置
    // ============================================================

    // 0：并行接口模式
    assign adc_par_ser_byte_sel = 1'b0;

    // 000：关闭过采样
    assign adc_os = 3'b000;

    // 1：±10V 输入范围；0：±5V 输入范围
    assign adc_range = 1'b1;

    // 1：正常工作；STBY=0 时进入 standby 或 shutdown
    assign adc_stby = 1'b1;

    // 1：使用内部参考源
    assign adc_ref_select = 1'b1;

    // ============================================================
    // 参数计算
    // ============================================================

    localparam integer SAMPLE_PERIOD_CLKS = SYS_CLK_HZ / SAMPLE_RATE_HZ;

    localparam [3:0]
        S_RESET       = 4'd0,
        S_IDLE        = 4'd1,
        S_CONVST_HIGH = 4'd2,
        S_WAIT_BUSY_H = 4'd3,
        S_WAIT_BUSY_L = 4'd4,
        S_READ_SETUP  = 4'd5,
        S_RD_LOW      = 4'd6,
        S_RD_SAMPLE   = 4'd7,
        S_RD_HIGH     = 4'd8,
        S_DONE        = 4'd9;

    reg [3:0]  state;
    reg [3:0]  ch_idx;
    reg [31:0] delay_cnt;
    reg [31:0] period_cnt;

    // ============================================================
    // 临时通道寄存器
    // ============================================================
    // AD7606/AD7606C 的并行数据是按通道顺序读出的。
    // 这里先把 V1~V4 暂存到 chx_tmp，等所有通道读完后，
    // 再在 S_DONE 状态把四路输出寄存器同时更新。

    reg signed [15:0] ch1_tmp;
    reg signed [15:0] ch2_tmp;
    reg signed [15:0] ch3_tmp;
    reg signed [15:0] ch4_tmp;

    // ============================================================
    // BUSY 同步到 FPGA 时钟域
    // ============================================================

    reg busy_d1;
    reg busy_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_d1 <= 1'b0;
            busy_d2 <= 1'b0;
        end else begin
            busy_d1 <= adc_busy;
            busy_d2 <= busy_d1;
        end
    end

    wire busy_sync = busy_d2;

    // ============================================================
    // 主状态机
    // ============================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_RESET;

            adc_convst_a <= 1'b0;
            adc_convst_b <= 1'b0;
            adc_cs_n     <= 1'b1;
            adc_rd_n     <= 1'b1;
            adc_reset    <= 1'b1;

            ch_idx       <= 4'd0;
            delay_cnt    <= 32'd0;
            period_cnt   <= 32'd0;

            ch1_tmp      <= 16'sd0;
            ch2_tmp      <= 16'sd0;
            ch3_tmp      <= 16'sd0;
            ch4_tmp      <= 16'sd0;

            ch1_data     <= 16'sd0;
            ch2_data     <= 16'sd0;
            ch3_data     <= 16'sd0;
            ch4_data     <= 16'sd0;
            data_valid   <= 1'b0;
        end else begin
            data_valid <= 1'b0;

            // 采样周期计数器：从一次 CONVST 上升沿开始计时
            if (period_cnt < SAMPLE_PERIOD_CLKS - 1)
                period_cnt <= period_cnt + 1'b1;

            case (state)

                // ====================================================
                // 上电或 FPGA 复位后，给 AD7606/AD7606C 一个 RESET 高脉冲
                // ====================================================
                S_RESET: begin
                    adc_convst_a <= 1'b0;
                    adc_convst_b <= 1'b0;
                    adc_cs_n     <= 1'b1;
                    adc_rd_n     <= 1'b1;
                    adc_reset    <= 1'b1;
                    period_cnt   <= 32'd0;

                    if (delay_cnt >= RESET_CLKS - 1) begin
                        delay_cnt <= 32'd0;
                        adc_reset <= 1'b0;
                        state     <= S_IDLE;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ====================================================
                // 等待采样周期到达
                // ====================================================
                S_IDLE: begin
                    adc_convst_a <= 1'b0;
                    adc_convst_b <= 1'b0;
                    adc_cs_n     <= 1'b1;
                    adc_rd_n     <= 1'b1;
                    adc_reset    <= 1'b0;

                    if (period_cnt >= SAMPLE_PERIOD_CLKS - 1) begin
                        period_cnt   <= 32'd0;
                        delay_cnt    <= 32'd0;
                        adc_convst_a <= 1'b1;
                        adc_convst_b <= 1'b1;
                        state        <= S_CONVST_HIGH;
                    end
                end

                // ====================================================
                // CONVST A/B 拉高，启动所有通道同步采样
                // ====================================================
                S_CONVST_HIGH: begin
                    adc_convst_a <= 1'b1;
                    adc_convst_b <= 1'b1;
                    adc_cs_n     <= 1'b1;
                    adc_rd_n     <= 1'b1;

                    if (delay_cnt >= CONVST_HIGH_CLKS - 1) begin
                        delay_cnt    <= 32'd0;
                        adc_convst_a <= 1'b0;
                        adc_convst_b <= 1'b0;
                        state        <= S_WAIT_BUSY_H;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ====================================================
                // 等待 BUSY 变高，确认 AD7606/AD7606C 已经开始转换
                // ====================================================
                S_WAIT_BUSY_H: begin
                    adc_convst_a <= 1'b0;
                    adc_convst_b <= 1'b0;
                    adc_cs_n     <= 1'b1;
                    adc_rd_n     <= 1'b1;

                    if (busy_sync) begin
                        state <= S_WAIT_BUSY_L;
                    end
                end

                // ====================================================
                // 等待 BUSY 变低，转换完成
                // ====================================================
                S_WAIT_BUSY_L: begin
                    adc_cs_n <= 1'b1;
                    adc_rd_n <= 1'b1;

                    if (!busy_sync) begin
                        delay_cnt <= 32'd0;
                        state     <= S_READ_SETUP;
                    end
                end

                // ====================================================
                // 读数据前，拉低 CS
                // ====================================================
                S_READ_SETUP: begin
                    adc_cs_n <= 1'b0;
                    adc_rd_n <= 1'b1;
                    ch_idx   <= 4'd0;

                    // 多等一个 clk，给总线一点建立时间
                    if (delay_cnt >= 1) begin
                        delay_cnt <= 32'd0;
                        state     <= S_RD_LOW;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ====================================================
                // RD 拉低，AD7606/AD7606C 将当前通道数据放到 DB[15:0]
                // ====================================================
                S_RD_LOW: begin
                    adc_cs_n <= 1'b0;
                    adc_rd_n <= 1'b0;

                    if (delay_cnt >= RD_LOW_CLKS - 1) begin
                        delay_cnt <= 32'd0;
                        state     <= S_RD_SAMPLE;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ====================================================
                // 采样 DB[15:0]
                // 第 1 次读出 V1，第 2 次读出 V2，依次类推。
                // 注意：这里不直接更新 chx_data，而是先写入 chx_tmp。
                // ====================================================
                S_RD_SAMPLE: begin
                    adc_cs_n <= 1'b0;
                    adc_rd_n <= 1'b0;

                    case (ch_idx)
                        4'd0: ch1_tmp <= adc_db;
                        4'd1: ch2_tmp <= adc_db;
                        4'd2: ch3_tmp <= adc_db;
                        4'd3: ch4_tmp <= adc_db;
                        default: begin
                            // V5~V8 仍然读出，但这里丢弃
                        end
                    endcase

                    delay_cnt <= 32'd0;
                    state     <= S_RD_HIGH;
                end

                // ====================================================
                // RD 拉高，准备读下一个通道
                // ====================================================
                S_RD_HIGH: begin
                    adc_cs_n <= 1'b0;
                    adc_rd_n <= 1'b1;

                    if (delay_cnt >= RD_HIGH_CLKS - 1) begin
                        delay_cnt <= 32'd0;

                        if (ch_idx >= ADC_TOTAL_CH - 1) begin
                            state <= S_DONE;
                        end else begin
                            ch_idx <= ch_idx + 1'b1;
                            state  <= S_RD_LOW;
                        end
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ====================================================
                // 一帧采样完成
                // 四路输出在同一个 clk 上升沿同步更新。
                // data_valid 同时拉高，用于提示上层锁存当前帧。
                // ====================================================
                S_DONE: begin
                    adc_cs_n <= 1'b1;
                    adc_rd_n <= 1'b1;

                    ch1_data <= ch1_tmp;
                    ch2_data <= ch2_tmp;
                    ch3_data <= ch3_tmp;
                    ch4_data <= ch4_tmp;

                    data_valid <= 1'b1;
                    state      <= S_IDLE;
                end

                default: begin
                    state <= S_RESET;
                end

            endcase
        end
    end

endmodule
