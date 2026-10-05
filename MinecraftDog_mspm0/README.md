## MinecraftDog MSPM0G3507 base project

This project provides a ready-to-call base layer for the drive motors,
quadrature encoders, SSD1306 OLED, and three ALX-AOA-FIT UWB anchors. All
periodic work is registered in `task.c`; `main()` only initializes the BSP and
runs the cooperative scheduler.

### Follow controller

`ALGORITHM/follow.c` implements a differential-drive distance/heading
controller. `Task_Follow_Control` runs it every 20 ms. The distance error
produces forward PWM, the signed UWB azimuth produces turning PWM, and the two
commands are mixed into left/right wheel commands. Forward PWM increases with
distance and is reduced as the heading error grows; at 90 degrees the robot
pivots instead of driving farther away. A command ramp limits sudden speed
changes.

The controller is disabled after reset for safe bench testing. Start and stop
it explicitly:

```c
Follow_Enable(1U); /* allow automatic following */
Follow_Enable(0U); /* immediate stop and motor lock */
```

Two public condition flags are ready for later FPGA communication:

- `g_follow_stop_flag == 1`: fresh target distance is at most 300 cm.
- `g_follow_lost_flag == 1`: target is missing/stale or farther than 2000 cm.

Both conditions stop the motors immediately. The gains, limits, and distance
thresholds are centralized in `ALGORITHM/follow.h` for vehicle tuning.

### Keys

Three active-low keys are sampled by `Task_Key_Scan` every 10 ms. The driver
uses a non-blocking state machine with 20 ms debounce and an 800 ms long-press
threshold. A long press is reported once while held and is not also reported as
a short press on release. Events are consumed through `KEY_TakeShortPress()`,
`KEY_TakeLongPress()`, or the `Key1_...`/`Key2_...`/`Key3_...` convenience
functions.

### UWB protocol

- Electrical interface: 3.3 V TTL UART, 115200 baud, 8 data bits, 1 stop bit,
  no parity, no hardware flow control.
- Location command: `0x2001`, 37-byte big-endian frame beginning with four
  `0xFF` bytes. The final byte is the XOR of all preceding bytes.
- The driver checks header, length, command, protocol version, and checksum.
- UART interrupts only enqueue bytes. `Task_UWB_Poll` parses them every 5 ms.
- `Task_UWB_Display` refreshes the blocking OLED once every 1000 ms.
- Measurements older than 500 ms are treated as unavailable.

The three antenna boresight offsets default to left `-90 deg`, forward `0 deg`,
and right `+90 deg`. Adjust `UWB_*_MOUNT_OFFSET_DEG` in
`HARDWARE/UWB/uwb.h` if the physical mounting angles differ. The fused result
uses the fresh anchor with the smallest absolute local azimuth, keeping the
selected measurement near the accurate center of its 120-degree sector.

```c
UWB_Target target;

if (UWB_GetTarget(Get_Time(), &target)) {
    /* target.azimuth_deg: vehicle-relative, left < 0, right > 0 */
    /* target.distance_cm: selected anchor-to-tag distance */
}
```

### Pin map

| Function | MSPM0G3507 pin | External connection |
| --- | --- | --- |
| UWB left TX / RX | PA21 / PA22 | MCU RX PA22 connects to anchor TX |
| UWB forward TX / RX | PA17 / PA18 | MCU RX PA18 connects to anchor TX |
| UWB right TX / RX | PA0 / PA1 | MCU RX PA1 connects to anchor TX |
| OLED I2C SDA / SCL | PA28 / PA31 | SSD1306 SDA / SCL |
| Motor PWM left / right | PA10 / PA11 | Driver PWM inputs |
| Motor AIN1 / AIN2 | PA12 / PA15 | Left motor direction inputs |
| Motor BIN1 / BIN2 | PA16 / PB17 | Right motor direction inputs |
| Encoder left A / B | PB13 / PB14 | Both-edge GPIO interrupts |
| Encoder right A / B | PB15 / PB16 | Both-edge GPIO interrupts |
| Key 1 / Key 2 / Key 3 | PA26 / PA25 / PA24 | Active-low inputs with internal pull-ups |
| Reserved FPGA/MLK TX / RX | PA14 / PA13 | Existing UART3 configuration unchanged |

For every UWB module, connect grounds directly. The MCU-to-anchor TX wire is
optional for the current active-report protocol, but its pin is reserved so
future commands can use a full UART pair.

### Task registration

Add future periodic work only to the `tasks[]` table in `task.c`. Keep fast,
non-blocking parsing/control tasks before the 1000 ms OLED task.

## Original SDK project notes

### Peripherals & Pin Assignments

| Peripheral | Pin | Function |
| --- | --- | --- |
| SYSCTL |  |  |
| DEBUGSS | PA20 | Debug Clock |
| DEBUGSS | PA19 | Debug Data In Out |

## BoosterPacks, Board Resources & Jumper Settings

Visit [LP_MSPM0G3507](https://www.ti.com/tool/LP-MSPM0G3507) for LaunchPad information, including user guide and hardware files.

| Pin | Peripheral | Function | LaunchPad Pin | LaunchPad Settings |
| --- | --- | --- | --- | --- |
| PA20 | DEBUGSS | SWCLK | N/A | <ul><li>PA20 is used by SWD during debugging<br><ul><li>`J101 15:16 ON` Connect to XDS-110 SWCLK while debugging<br><li>`J101 15:16 OFF` Disconnect from XDS-110 SWCLK if using pin in application</ul></ul> |
| PA19 | DEBUGSS | SWDIO | N/A | <ul><li>PA19 is used by SWD during debugging<br><ul><li>`J101 13:14 ON` Connect to XDS-110 SWDIO while debugging<br><li>`J101 13:14 OFF` Disconnect from XDS-110 SWDIO if using pin in application</ul></ul> |

### Device Migration Recommendations
This project was developed for a superset device included in the LP_MSPM0G3507 LaunchPad. Please
visit the [CCS User's Guide](https://software-dl.ti.com/msp430/esd/MSPM0-SDK/latest/docs/english/tools/ccs_ide_guide/doc_guide/doc_guide-srcs/ccs_ide_guide.html#sysconfig-project-migration)
for information about migrating to other MSPM0 devices.

### Low-Power Recommendations
TI recommends to terminate unused pins by setting the corresponding functions to
GPIO and configure the pins to output low or input with internal
pullup/pulldown resistor.

SysConfig allows developers to easily configure unused pins by selecting **Board**→**Configure Unused Pins**.

For more information about jumper configuration to achieve low-power using the
MSPM0 LaunchPad, please visit the [LP-MSPM0G3507 User's Guide](https://www.ti.com/lit/slau873).

## Example Usage

Compile, load and run the example.
