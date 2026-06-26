# AD7606C 并行采样控制工程说明

本工程用于 FPGA 通过并行接口控制 AD7606/AD7606C 系列同步采样 ADC。当前逻辑采用 **并行总线读取**，FPGA 定时产生 `CONVST A/B`，等待 ADC `BUSY` 转换完成后，依次通过 `RD` 读取各通道转换结果。工程目前只向上层输出前 4 路数据 `ch1_data ~ ch4_data`，但如果实际芯片为 8 通道版本，仍会按顺序读满 8 路，其中 V5~V8 在逻辑中丢弃。

当前设计重点是：

1. 用独立 `sample_tick_gen` 产生严格采样节拍；
2. `CONVST A/B` 只由固定周期 `sample_tick` 触发；
3. ADC 读数状态机必须在一个采样周期内完成转换等待和并口读数；
4. `data_valid` 与采样节拍对齐输出，输出数据相对 ADC 采样固定延迟一帧；
5. 四路数据先进入临时寄存器和帧缓冲，再在同一个时钟沿同步输出。

---

## 1. 工程文件说明

| 文件 | 作用 |
|---|---|
| `sources_1/new/top.v` | ADC 并行采样顶层控制模块，包含 AD7606C 控制信号、并行读数状态机、四通道输出逻辑 |
| `sources_1/new/sample_tick_gen.v` | 独立采样节拍发生器，按照 `SYS_CLK_HZ / SAMPLE_RATE_HZ` 周期产生 1 个 `clk` 宽度的 `sample_tick` |
| `sim_1/new/testbench.v` | 仿真测试文件，包含简化 ADC 行为模型，用于验证 `CONVST`、`BUSY`、`RD`、并口数据读取和 `data_valid` 输出节拍 |

---

## 2. 顶层模块接口总览

当前顶层模块为：

```verilog
module top #(
    parameter integer SYS_CLK_HZ       = 50_000_000,
    parameter integer SAMPLE_RATE_HZ   = 100_000,
    parameter integer ADC_TOTAL_CH     = 8,
    parameter integer RESET_CLKS       = 10,
    parameter integer CONVST_HIGH_CLKS = 2,
    parameter integer RD_LOW_CLKS      = 2,
    parameter integer RD_HIGH_CLKS     = 2
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        adc_busy,
    input  wire [15:0] adc_db,
    input  wire        adc_frstdata,

    output reg         adc_convst_a,
    output reg         adc_convst_b,
    output reg         adc_cs_n,
    output reg         adc_rd_n,
    output reg         adc_reset,

    output wire        adc_par_ser_byte_sel,
    output wire [2:0]  adc_os,
    output wire        adc_range,
    output wire        adc_stby,
    output wire        adc_ref_select,

    output reg signed [15:0] ch1_data,
    output reg signed [15:0] ch2_data,
    output reg signed [15:0] ch3_data,
    output reg signed [15:0] ch4_data,
    output reg               data_valid
);
```

注意：这里的“输入/输出”方向是以 **FPGA 顶层模块 `top.v`** 为参照，而不是以 AD7606C 芯片为参照。

---

## 3. 哪些信号需要真正连接到 ADC 板卡

需要分成三类理解：

1. **必须连接到 ADC 板卡的外部物理引脚**；
2. **可以由 FPGA 控制，也可以在硬件上固定到高/低电平的配置引脚**；
3. **只给 FPGA 内部上层逻辑使用，不需要约束到外部板卡引脚的内部数据接口**。

### 3.1 必须连接到 ADC 板卡的信号

这些信号直接参与 AD7606C 转换和并行读数，一般需要在 XDC 中分配 FPGA 管脚，并连接到 ADC 模块或 ADC 芯片对应引脚。

| FPGA 顶层信号 | FPGA 方向 | AD7606C 方向 | 是否必须接板卡 | 作用 |
|---|---:|---:|---:|---|
| `adc_convst_a` | 输出 | 输入 | 是 | 转换启动信号 A。上升沿使 A 组通道采样保持，并启动转换流程的一部分 |
| `adc_convst_b` | 输出 | 输入 | 是 | 转换启动信号 B。通常与 `adc_convst_a` 同时驱动，实现所有通道同步采样 |
| `adc_busy` | 输入 | 输出 | 是 | ADC 转换忙信号。高电平表示 ADC 正在转换，低电平表示转换完成、数据可读 |
| `adc_cs_n` | 输出 | 输入 | 是 | ADC 片选信号，低有效。并行读数时拉低以使能 ADC 数据输出接口 |
| `adc_rd_n` | 输出 | 输入 | 是 | 并行读控制信号，低有效。每产生一个读脉冲，ADC 输出下一个通道的数据 |
| `adc_db[15:0]` | 输入 | 输出 | 是 | 16 bit 并行数据总线。ADC 通过该总线输出每个通道的转换结果 |
| `adc_reset` | 输出 | 输入 | 通常需要 | ADC 复位信号。上电或系统复位后给出有效复位脉冲，使 ADC 接口状态回到初始状态 |

这些信号是并行采样功能的核心。如果缺少其中任意一个，FPGA 就无法完整控制 ADC 的采样、转换等待和数据读取过程。

---

### 3.2 可由 FPGA 控制，也可由硬件固定的配置引脚

这些信号不是每一帧采样都动态变化的信号，而是模式配置或工作状态选择信号。当前 `top.v` 将它们作为输出端口给出，方便由 FPGA 控制；如果你的 ADC 板卡已经用电阻把这些引脚固定到高/低电平，则可以不从 FPGA 引出这些端口。

| FPGA 顶层信号 | FPGA 方向 | AD7606C 方向 | 当前代码值 | 是否必须接 FPGA | 作用 |
|---|---:|---:|---:|---:|---|
| `adc_par_ser_byte_sel` | 输出 | 输入 | `0` | 不一定 | 接低电平选择并行接口模式；接高电平用于串行/字节接口相关模式 |
| `adc_os[2:0]` | 输出 | 输入 | `000` | 不一定 | 过采样倍率选择。当前为 `000`，表示关闭过采样 |
| `adc_range` | 输出 | 输入 | `1` | 不一定 | 模拟输入量程选择。当前为 `1`，通常对应 ±10 V；为 `0` 时通常对应 ±5 V |
| `adc_stby` | 输出 | 输入 | `1` | 不一定 | 待机/关断控制。当前为 `1`，表示正常工作 |
| `adc_ref_select` | 输出 | 输入 | `1` | 不一定 | 参考源选择。当前为 `1`，表示使用内部参考源；具体含义应以实际 AD7606C 手册和板卡原理图为准 |

建议：

- 如果你希望后续通过 FPGA 动态切换量程、过采样倍率或工作模式，则把这些信号接到 FPGA，并在 XDC 中分配管脚；
- 如果你的设计只固定使用并行模式、固定量程、固定过采样配置，则可以在硬件上用上拉/下拉电阻固定，不必占用 FPGA IO；
- 如果硬件已经固定这些配置引脚，而 `top.v` 中仍保留对应输出端口，需要避免在 XDC 中重复约束到不存在的 FPGA 管脚。

---

### 3.3 可选连接或调试用信号

| FPGA 顶层信号 | FPGA 方向 | AD7606C 方向 | 是否必须接 | 作用 |
|---|---:|---:|---:|---|
| `adc_frstdata` | 输入 | 输出 | 否，建议可接作调试 | 第一个通道数据指示信号。读出 V1 时该信号有效，可用于检查 RD 计数是否与 ADC 输出通道顺序对齐 |

当前逻辑没有依赖 `adc_frstdata` 完成通道读取，而是通过内部 `ch_idx` 计数器按 `RD` 顺序识别 V1、V2、V3、V4 等通道。因此在单片 ADC、固定每帧读满所有通道的情况下，`FRSTDATA` 不是功能必需信号。

但是它并不是完全无用。实际调试中可以用 ILA 抓取 `adc_frstdata`，用于判断：

- 第一个 `RD` 脉冲是否真的对应 V1；
- 是否发生多发/少发 `RD` 导致通道错位；
- 并行读数帧边界是否正确。

因此建议：如果 FPGA IO 资源充足，可以连接 `adc_frstdata`；如果 IO 紧张，可以不使用它。

---

### 3.4 不需要输出到 ADC 板卡的内部逻辑信号

以下信号是 FPGA 内部处理结果或上层模块接口，不应该直接接到 AD7606C 板卡。

| 信号 | 方向 | 是否接 ADC 板卡 | 作用 |
|---|---:|---:|---|
| `clk` | 输入 | 不接 ADC 板卡 | FPGA 系统时钟，例如 50 MHz，由 FPGA 板卡时钟源提供 |
| `rst_n` | 输入 | 不接 ADC 板卡 | FPGA 逻辑复位信号，由按键、复位芯片或上层系统提供 |
| `ch1_data` | 输出 | 不接 ADC 板卡 | FPGA 内部输出的第 1 路 ADC 采样结果，给后级处理模块使用 |
| `ch2_data` | 输出 | 不接 ADC 板卡 | FPGA 内部输出的第 2 路 ADC 采样结果，给后级处理模块使用 |
| `ch3_data` | 输出 | 不接 ADC 板卡 | FPGA 内部输出的第 3 路 ADC 采样结果，给后级处理模块使用 |
| `ch4_data` | 输出 | 不接 ADC 板卡 | FPGA 内部输出的第 4 路 ADC 采样结果，给后级处理模块使用 |
| `data_valid` | 输出 | 不接 ADC 板卡 | 四路输出数据有效标志，和 `ch1_data~ch4_data` 同拍有效 |
| `sample_tick` | 内部 wire | 不接 ADC 板卡 | 严格采样节拍，由 `sample_tick_gen.v` 内部产生 |
| `sample_overrun` | 内部调试 reg | 不接 ADC 板卡 | 采样周期到来时状态机仍未空闲，说明当前采样率或读数时序超限 |
| `sample_underrun` | 内部调试 reg | 不接 ADC 板卡 | 采样周期到来时上一帧尚未准备好，说明输出数据出现断帧 |

如果后续需要通过引脚、LED 或逻辑分析仪观察 `data_valid`、`sample_overrun` 等调试信号，可以单独引出；但它们不是 ADC 板卡接口的一部分。

---

## 4. 推荐的 ADC 板卡连接关系

以 FPGA 控制 AD7606C 并行接口为例，推荐连接如下：

```text
FPGA                                      AD7606C / ADC 板卡
----------------------------------------------------------------
adc_convst_a        ------------------>   CONVST A
adc_convst_b        ------------------>   CONVST B
adc_cs_n            ------------------>   CS
adc_rd_n            ------------------>   RD / SCLK   // 并行模式下作为 RD
adc_reset           ------------------>   RESET

adc_busy            <------------------   BUSY
adc_db[15:0]        <------------------   DB[15:0]
adc_frstdata        <------------------   FRSTDATA    // 可选，调试用

adc_par_ser_byte_sel ------------------>   PAR/SER/BYTE SEL  // 或硬件固定为 0
adc_os[2:0]          ------------------>   OS[2:0]            // 或硬件固定
adc_range            ------------------>   RANGE              // 或硬件固定
adc_stby             ------------------>   STBY               // 或硬件固定
adc_ref_select       ------------------>   REF SELECT          // 或硬件固定
```

如果 ADC 板卡已经把 `PAR/SER/BYTE SEL`、`OS[2:0]`、`RANGE`、`STBY`、`REF SELECT` 固定到某个电平，FPGA 侧就不要再强行驱动这些引脚。

---

## 5. 并行采样时序说明

当前逻辑采用如下采样和读数流程：

```text
sample_tick 到来
    ↓
FPGA 同时拉高 adc_convst_a / adc_convst_b
    ↓
保持 CONVST 高电平若干 clk，满足 ADC 最小脉宽
    ↓
CONVST 拉低
    ↓
等待 adc_busy 变高，确认 ADC 开始转换
    ↓
等待 adc_busy 变低，确认转换完成
    ↓
拉低 adc_cs_n
    ↓
依次产生 adc_rd_n 读脉冲
    ↓
第 1 次 RD：读取 V1
第 2 次 RD：读取 V2
第 3 次 RD：读取 V3
第 4 次 RD：读取 V4
第 5~8 次 RD：读取但丢弃 V5~V8
    ↓
当前帧写入 ch1_buf~ch4_buf
    ↓
下一个 sample_tick 到来时，同步输出 ch1_data~ch4_data，并拉高 data_valid
```

因此，当前输出数据相对于实际 ADC 采样时刻固定延迟一帧。这样做的好处是：

- `CONVST` 采样时刻严格由 `sample_tick` 决定；
- `data_valid` 也与 `sample_tick` 对齐；
- 四路数据在同一个 `clk` 上升沿同步变化；
- 如果 ADC 转换和读取无法在一个采样周期内完成，会通过内部调试信号 `sample_overrun` / `sample_underrun` 暴露问题，而不是悄悄推迟采样时刻。

---

## 6. 当前参数含义

| 参数 | 当前默认值 | 含义 |
|---|---:|---|
| `SYS_CLK_HZ` | `50_000_000` | FPGA 系统时钟频率，默认 50 MHz |
| `SAMPLE_RATE_HZ` | `100_000` | 目标采样率，默认 100 kHz |
| `ADC_TOTAL_CH` | `8` | 每帧需要从 ADC 读出的通道总数。8 通道芯片设为 8，4 通道芯片可设为 4 |
| `RESET_CLKS` | `10` | ADC 复位高电平持续的系统时钟周期数 |
| `CONVST_HIGH_CLKS` | `2` | `CONVST A/B` 高电平持续的系统时钟周期数 |
| `RD_LOW_CLKS` | `2` | `RD` 低电平持续的系统时钟周期数 |
| `RD_HIGH_CLKS` | `2` | `RD` 高电平持续的系统时钟周期数 |

以 50 MHz 系统时钟为例：

```text
1 clk = 20 ns
SAMPLE_RATE_HZ = 100 kHz -> sample_tick 周期 = 10 us
CONVST_HIGH_CLKS = 2 -> CONVST 高电平宽度 = 40 ns
RD_LOW_CLKS = 2 -> RD 低电平宽度 = 40 ns
RD_HIGH_CLKS = 2 -> RD 高电平宽度 = 40 ns
```

实际使用 AD7606C 时，应根据 AD7606C 数据手册和板卡电平条件重新核对 `CONVST`、`RD`、`CS`、`BUSY` 的最小时序参数。

---

## 7. XDC 约束建议

### 7.1 必须约束的外部接口

如果这些信号实际连接到 FPGA 管脚，则需要在 XDC 中约束：

```tcl
# 系统时钟和复位
set_property PACKAGE_PIN <PIN> [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 20.000 -name clk [get_ports clk]

set_property PACKAGE_PIN <PIN> [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

# ADC 控制信号，FPGA -> ADC
set_property PACKAGE_PIN <PIN> [get_ports adc_convst_a]
set_property PACKAGE_PIN <PIN> [get_ports adc_convst_b]
set_property PACKAGE_PIN <PIN> [get_ports adc_cs_n]
set_property PACKAGE_PIN <PIN> [get_ports adc_rd_n]
set_property PACKAGE_PIN <PIN> [get_ports adc_reset]

# ADC 状态和数据，ADC -> FPGA
set_property PACKAGE_PIN <PIN> [get_ports adc_busy]
set_property PACKAGE_PIN <PIN> [get_ports adc_db[*]]

# 可选调试信号
set_property PACKAGE_PIN <PIN> [get_ports adc_frstdata]
```

上面的 `<PIN>` 需要替换为你的 FPGA 板卡和 ADC 模块实际连接的管脚。

### 7.2 不建议直接约束的内部信号

不要在 XDC 中约束这些内部或上层接口信号到 ADC 板卡：

```text
ch1_data
ch2_data
ch3_data
ch4_data
data_valid
sample_tick
sample_overrun
sample_underrun
```

除非你明确希望把它们输出到测试排针、LED 或其他外部调试接口。

---

## 8. 仿真说明

仿真文件 `sim_1/new/testbench.v` 包含一个简化 ADC 行为模型：

1. 在 `adc_convst_a` 上升沿生成一帧 ADC 数据；
2. 将 `adc_busy` 拉高一段固定时间模拟转换；
3. 在每个 `adc_rd_n` 下降沿依次输出 V1~V8；
4. 检查 `data_valid` 是否严格以 100 kHz 周期出现；
5. 检查 `ch1_data~ch4_data` 是否与期望数据一致。

仿真通过时会打印：

```text
TEST PASSED: 10 valid frames checked successfully.
```

如果出现 `data_valid period mismatch`、`chx mismatch`、`sample_overrun` 或 `sample_underrun`，说明采样节拍、ADC 转换模型、并口读数时序或输出帧对齐存在问题。

---

## 9. 常见问题

### 9.1 `FRSTDATA` 是否必须使用？

不是必须。当前逻辑通过 `ch_idx` 记录 RD 脉冲个数，并按顺序读取 V1~V8。在单片 ADC、固定每帧读满通道的情况下，不依赖 `FRSTDATA` 也可以正确工作。

但是 `FRSTDATA` 可作为帧头对齐和调试信号。如果出现通道错位问题，可以用 ILA 同时抓取：

```text
adc_cs_n
adc_rd_n
adc_db[15:0]
adc_frstdata
ch_idx
```

用于确认第一个 RD 脉冲是否确实对应 V1。

### 9.2 为什么只输出 4 路，但仍然读 8 路？

如果实际使用的是 8 通道 AD7606/AD7606C，ADC 每帧会按顺序提供 8 个通道结果。当前逻辑只保留 V1~V4，但仍然读出 V5~V8 并丢弃，这样可以保持 ADC 读指针和下一帧读取顺序稳定。

如果实际使用的是 4 通道版本，或你的 AD7606C 配置确实只输出 4 路，则可以将：

```verilog
parameter integer ADC_TOTAL_CH = 4;
```

### 9.3 为什么 `data_valid` 延迟一帧？

因为 ADC 在 `CONVST` 上升沿之后还需要转换和读数，不可能在同一个采样时刻立即输出当前帧。当前设计让 `data_valid` 在下一个 `sample_tick` 输出上一帧数据，从而保证输出节拍严格等于目标采样率。

### 9.4 如果 `sample_overrun` 被拉高怎么办？

说明一个采样周期内没有完成：

```text
CONVST 脉冲
BUSY 转换等待
CS/RD 并行读数
S_DONE 帧缓存
```

解决方法包括：

1. 降低 `SAMPLE_RATE_HZ`；
2. 减小 `RD_LOW_CLKS` / `RD_HIGH_CLKS`，但必须满足 AD7606C 手册时序；
3. 提高 FPGA 系统时钟频率；
4. 改成转换期间读取上一帧数据的流水结构；
5. 如果只需要 4 通道，并且 ADC 支持只输出 4 通道，则将 `ADC_TOTAL_CH` 改为 4。

### 9.5 ADC 模拟输入 V1~V8 是否是 FPGA 信号？

不是。V1~V8 是 AD7606C 的模拟输入端，应该接实际模拟信号源，不是 FPGA 数字管脚。FPGA 只通过数字控制接口获取转换后的 `adc_db[15:0]` 数据。
