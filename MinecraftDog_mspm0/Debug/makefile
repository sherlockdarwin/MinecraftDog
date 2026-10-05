################################################################################
# Automatically-generated file. Do not edit!
################################################################################

CG_TOOL_ROOT := /Applications/ti/ccs2100/ccs/tools/compiler/ti-cgt-armllvm_5.1.1.LTS

GEN_OPTS__FLAG := @"./device.opt" 
GEN_CMDS__FLAG := -Wl,-l"./device_linker.cmd" 

ORDERED_OBJS += \
"./empty.o" \
"./ti_msp_dl_config.o" \
"./startup_mspm0g350x_ticlang.o" \
"./task.o" \
"./ALGORITHM/follow.o" \
"./HARDWARE/KEY/key.o" \
"./HARDWARE/MLK/fpgamlk.o" \
"./HARDWARE/MOTOR/encoder.o" \
"./HARDWARE/MOTOR/motor.o" \
"./HARDWARE/OLED/oled_hardware_i2c.o" \
"./HARDWARE/UWB/uwb.o" \
"./SYSTEM/bsp.o" \
"./SYSTEM/delay.o" \
$(GEN_CMDS__FLAG) \
-Wl,-ldevice.cmd.genlibs \
-Wl,-llibc.a \

-include ../makefile.init

RM := rm -rf
RMDIR := rm -rf

# All of the sources participating in the build are defined here
-include sources.mk
-include subdir_vars.mk
-include ALGORITHM/subdir_vars.mk
-include HARDWARE/KEY/subdir_vars.mk
-include HARDWARE/MLK/subdir_vars.mk
-include HARDWARE/MOTOR/subdir_vars.mk
-include HARDWARE/OLED/subdir_vars.mk
-include HARDWARE/UWB/subdir_vars.mk
-include SYSTEM/subdir_vars.mk
-include subdir_rules.mk
-include ALGORITHM/subdir_rules.mk
-include HARDWARE/KEY/subdir_rules.mk
-include HARDWARE/MLK/subdir_rules.mk
-include HARDWARE/MOTOR/subdir_rules.mk
-include HARDWARE/OLED/subdir_rules.mk
-include HARDWARE/UWB/subdir_rules.mk
-include SYSTEM/subdir_rules.mk
-include objects.mk

ifneq ($(MAKECMDGOALS),clean)
ifneq ($(strip $(C55_DEPS)),)
-include $(C55_DEPS)
endif
ifneq ($(strip $(C_UPPER_DEPS)),)
-include $(C_UPPER_DEPS)
endif
ifneq ($(strip $(S67_DEPS)),)
-include $(S67_DEPS)
endif
ifneq ($(strip $(S62_DEPS)),)
-include $(S62_DEPS)
endif
ifneq ($(strip $(S_DEPS)),)
-include $(S_DEPS)
endif
ifneq ($(strip $(OPT_DEPS)),)
-include $(OPT_DEPS)
endif
ifneq ($(strip $(C??_DEPS)),)
-include $(C??_DEPS)
endif
ifneq ($(strip $(ASM_UPPER_DEPS)),)
-include $(ASM_UPPER_DEPS)
endif
ifneq ($(strip $(S??_DEPS)),)
-include $(S??_DEPS)
endif
ifneq ($(strip $(C64_DEPS)),)
-include $(C64_DEPS)
endif
ifneq ($(strip $(CXX_DEPS)),)
-include $(CXX_DEPS)
endif
ifneq ($(strip $(S64_DEPS)),)
-include $(S64_DEPS)
endif
ifneq ($(strip $(CLA_DEPS)),)
-include $(CLA_DEPS)
endif
ifneq ($(strip $(S55_DEPS)),)
-include $(S55_DEPS)
endif
ifneq ($(strip $(SV7A_DEPS)),)
-include $(SV7A_DEPS)
endif
ifneq ($(strip $(C62_DEPS)),)
-include $(C62_DEPS)
endif
ifneq ($(strip $(C67_DEPS)),)
-include $(C67_DEPS)
endif
ifneq ($(strip $(K_DEPS)),)
-include $(K_DEPS)
endif
ifneq ($(strip $(C_DEPS)),)
-include $(C_DEPS)
endif
ifneq ($(strip $(CC_DEPS)),)
-include $(CC_DEPS)
endif
ifneq ($(strip $(C++_DEPS)),)
-include $(C++_DEPS)
endif
ifneq ($(strip $(C43_DEPS)),)
-include $(C43_DEPS)
endif
ifneq ($(strip $(S43_DEPS)),)
-include $(S43_DEPS)
endif
ifneq ($(strip $(ASM_DEPS)),)
-include $(ASM_DEPS)
endif
ifneq ($(strip $(S_UPPER_DEPS)),)
-include $(S_UPPER_DEPS)
endif
ifneq ($(strip $(CPP_DEPS)),)
-include $(CPP_DEPS)
endif
ifneq ($(strip $(SA_DEPS)),)
-include $(SA_DEPS)
endif
endif

-include ../makefile.defs

# Add inputs and outputs from these tool invocations to the build variables 
EXE_OUTPUTS += \
MinecraftDog_mspm0.out 

EXE_OUTPUTS__QUOTED += \
"MinecraftDog_mspm0.out" 


# All Target
all: $(OBJS) $(GEN_CMDS)
	@$(MAKE) --no-print-directory -Onone "MinecraftDog_mspm0.out"

# Tool invocations
MinecraftDog_mspm0.out: $(OBJS) $(GEN_CMDS)
	@echo 'Arm Linker - building target: "$@"'
	"/Applications/ti/ccs2100/ccs/tools/compiler/ti-cgt-armllvm_5.1.1.LTS/bin/tiarmclang" @"device.opt"  -march=thumbv6m -mcpu=cortex-m0plus -mfloat-abi=soft -mlittle-endian -mthumb -O2 -gdwarf-3 -Wall -Wl,-m"MinecraftDog_mspm0.map" -Wl,-i"/Applications/ti/mspm0_sdk_2_10_00_04/source" -Wl,-i"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0" -Wl,-i"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/Debug/syscfg" -Wl,-i"/Applications/ti/ccs2100/ccs/tools/compiler/ti-cgt-armllvm_5.1.1.LTS/lib" -Wl,--diag_wrap=off -Wl,--display_error_number -Wl,--warn_sections -Wl,--xml_link_info="MinecraftDog_mspm0_linkInfo.xml" -Wl,--rom_model -o "MinecraftDog_mspm0.out" $(ORDERED_OBJS)
	@echo 'Finished building target: "$@"'
	@echo ' '

# Other Targets
clean:
	-$(RM) $(GEN_MISC_FILES__QUOTED)$(GEN_FILES__QUOTED)$(EXE_OUTPUTS__QUOTED)
	-$(RM) "empty.o" "ti_msp_dl_config.o" "startup_mspm0g350x_ticlang.o" "task.o" "ALGORITHM/follow.o" "HARDWARE/KEY/key.o" "HARDWARE/MLK/fpgamlk.o" "HARDWARE/MOTOR/encoder.o" "HARDWARE/MOTOR/motor.o" "HARDWARE/OLED/oled_hardware_i2c.o" "HARDWARE/UWB/uwb.o" "SYSTEM/bsp.o" "SYSTEM/delay.o" 
	-$(RM) "empty.d" "ti_msp_dl_config.d" "startup_mspm0g350x_ticlang.d" "task.d" "ALGORITHM/follow.d" "HARDWARE/KEY/key.d" "HARDWARE/MLK/fpgamlk.d" "HARDWARE/MOTOR/encoder.d" "HARDWARE/MOTOR/motor.d" "HARDWARE/OLED/oled_hardware_i2c.d" "HARDWARE/UWB/uwb.d" "SYSTEM/bsp.d" "SYSTEM/delay.d" 
	-@echo ' '

.PHONY: all clean dependents
.SECONDARY:

-include ../makefile.targets

