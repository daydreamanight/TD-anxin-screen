# 安芯讯屏：校园应急与公共信息终端

基于安路 EG4S20 的 HDMI 多媒体播放系统。

## 作品简介

本作品基于 HX4S20C 开发板，面向教学楼、实验楼和图书馆等校园公共空间，是一套可离线运行的信息终端。系统通过 SPI 读取 TF 卡中的 BMP 图片，经 FAT32 与 BMP 解析、FIFO 和 SDRAM 双帧缓存，由 HDMI 输出 640×480 画面和标称 48 kHz 音频。日常支持自动轮播和按键翻页；管理员可人工发布应急提示页，加载转场后锁定显示。全部逻辑由 FPGA 硬件实现，不含处理器核。

## 功能

- TF 卡读取 24 位 BMP，FAT32 解析，不同尺寸图片最近邻缩放到全屏
- HDMI 640×480 视频和音频输出，淡入淡出转场，页面提示音
- 自动轮播，按键前后翻页；页面顺序、停留时间和声音模式由 `SCREEN.CFG` 离线设置
- 人工触发应急提示：加载转场后锁定，一次提示音，默认显示参数，长按解除
- 动态状态文字和滚动字幕；活动日页面实时叠加预设路线
- 维护界面：亮度与对比度调节、运行诊断、同源 PCM 时域波形
- 有线串口辅助控制，回执区分“已接受”和“已呈现”

## 硬件需求

| 项目 | 说明 |
|---|---|
| 开发板 | HX4S20C（EG4S20BG256） |
| 显示器 | HDMI 接口，接开发板 HDMI A 口，支持 640×480 |
| TF 卡 | FAT32 格式 |
| USB 串口线 | 可选，用于串口工具 |

模式引脚 `mode_sw`（C8、C7）两位相同时为正常播放，默认上拉即可。

## 目录结构

```text
anxin_screen/
├── README.md
├── SHA256SUMS.txt
├── doc/                  用户说明书、串口工具界面图
├── prj/                  TD 工程
│   ├── anxin_screen.al   工程文件
│   ├── build.bat         构建脚本
│   ├── build_td.tcl      构建流程
│   ├── scripts/          构建中的时序和跨时钟检查
│   ├── al_ip/            PLL
│   └── bitstream/        比特流和 SHA256
├── source_code/
│   ├── adc_sdc/          引脚和时序约束（anxin_screen_quick.sdc 供 TD 界面的 Run 使用）
│   ├── rtl/              top、storage、memory、video、audio、control、uart、common、vendor
│   └── tb/               测试平台
├── sim_do/               仿真脚本
├── sd_card/              TF 卡文件
└── pc_tool/              串口控制台
```

## 开发环境

| 工具 | 版本 |
|---|---|
| 安路 Tang Dynasty | TD_6.2.1_Engineer_168116 |
| ModelSim | ModelSim ALTERA STARTER EDITION 10.3c |
| Python | 3.x（构建检查和串口工具） |

## 构建

**正式构建：** 设置环境变量 `TD_HOME` 为 Tang Dynasty 安装目录，或把它的 `bin` 目录加入 `PATH`，然后运行：

```bat
prj\build.bat
```

约 8 分钟，结果在 `prj\build\td\`，显示 `BUILD OK` 表示流程和全部检查通过。这个流程包含完整的时序约束、跨时钟检查和保持时间修复，`prj\bitstream\` 中的比特流就由它生成。

**在 TD 界面中编译：** 用 TD 打开 `prj\anxin_screen.al`，点 Run 即可，约 5 分钟，时序满足要求。两条流程的布局结果不同；板上验证针对的是 `prj\bitstream\` 中的比特流。

资源：LUT 17251/19600（88.02%），寄存器 10768/19600（54.94%），BRAM9K 42/64（65.62%），DSP 7/29（24.14%），PLL 3/4。时序：setup +0.047 ns，hold +0.024 ns。

比特流文件头含有构建时间，所以重新构建后文件的 SHA256 会变；去掉 `# Date` 这一行后，内容与 `prj\bitstream\anxin_screen.bit` 完全相同。

## 下载与固化

在 TD 的下载工具中选择 `prj\bitstream\anxin_screen.bit`，或在 `bw_commands_prompt` 中运行：

```tcl
# 下载到 SRAM，断电后丢失
download -bit {prj/bitstream/anxin_screen.bit} -mode jtag -spd 7 -cable 0
# 写入配置 Flash 并校验，上电自动运行
download -bit {prj/bitstream/anxin_screen.bit} -mode program_spi -v -spd 7 -cable 0 -flashsize 16
```

## TF 卡准备

把 `sd_card\` 里的 6 个文件复制到 FAT32 TF 卡的根目录，关机后插卡，再开机。

## 仿真

把 ModelSim 的 `win32aloem` 目录加入 `PATH`，然后运行：

```bat
sim_do\run_all.bat
```

共 17 个测试平台，约 5 分钟。

## 串口工具

需要 Python 3 和 pyserial（`pip install pyserial`）。双击 `pc_tool\tools\serial_control\start.cmd`，用法见[用户说明书](doc/user_manual.md)。

## 文件校验

所有文件的 SHA256 见 `SHA256SUMS.txt`。主要文件：

| 文件 | SHA256 |
|---|---|
| `prj/bitstream/anxin_screen.bit` | `7BFD8D5E7EB9129DFAA9F385505BA130D914C87E56191495C3E7B1813BD7E316` |
| `sd_card/PIC1.BMP` | `781571F5A2C60CC9C3A31CB61030EACB89989D1B2445FE3017F4360D6919BFB9` |
| `sd_card/PIC2.BMP` | `38EE74638CE51D6478DEA8D7F68CF84F8914E37D8F1118D88A708FCEAF29A36B` |
| `sd_card/PIC3.BMP` | `D864D7B81A40070CA1A7F4A0EC000EFC79B0762A62BCA7A8C4DEE2B71FC7932E` |
| `sd_card/PIC4.BMP` | `76F6FE2179FDDB77F6A0A2BEAC0DB1ACE1F74E200E0468F384105C7E5779FF67` |
| `sd_card/PIC5.BMP` | `155DF8E4530C7883CA37DF07A72F0CAC61D636EFF62210BB5D80416E400C7245` |
| `sd_card/SCREEN.CFG` | `2BA17EF4C209305B21459B5F7A054B19DE3DAFFB2F2AC3990FC5DF7F1C21CA2E` |

## 第三方 IP

HDMI 发送核、SDRAM 控制器和 PLL 是安路官方 IP；SD 读写、数码管驱动等基于开发板官方例程。这些文件在 `source_code/rtl/vendor/` 和 `prj/al_ip/` 中，保持原样。其余 RTL 为本作品自行编写。
