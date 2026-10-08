################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Each subdirectory must supply rules for building sources it contributes
%.o: ../%.c $(GEN_OPTS) | $(GEN_FILES) $(GEN_MISC_FILES)
	@echo 'Arm Compiler - building file: "$<"'
	"/Applications/ti/ccs2100/ccs/tools/compiler/ti-cgt-armllvm_5.1.1.LTS/bin/tiarmclang" -c @"device.opt"  -march=thumbv6m -mcpu=cortex-m0plus -mfloat-abi=soft -mlittle-endian -mthumb -O2 -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/OLED" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/UWB" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/MOTOR" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/SYSTEM" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/Debug" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source/third_party/CMSIS/Core/Include" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source" -gdwarf-3 -Wall -MMD -MP -MF"$(basename $(<F)).d_raw" -MT"$(@)"  $(GEN_OPTS__FLAG) -o"$@" "$<"
	@echo 'Finished building: "$<"'
	@echo ' '

build-1189365202: ../empty.syscfg
	@echo 'SysConfig - building file: "$<"'
	"/Applications/ti/ccs2100/ccs/utils/sysconfig_1.28.0/sysconfig_cli.sh" -s "/Applications/ti/mspm0_sdk_2_10_00_04/.metadata/product.json" -s "/Applications/ti/mspm0_sdk_2_10_00_04/.metadata/product.json" --script "/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/empty.syscfg" -o "." --compiler ticlang
	@echo 'Finished building: "$<"'
	@echo ' '

device_linker.cmd: build-1189365202 ../empty.syscfg
device.opt: build-1189365202
device.cmd.genlibs: build-1189365202
ti_msp_dl_config.c: build-1189365202
ti_msp_dl_config.h: build-1189365202
Event.dot: build-1189365202

%.o: ./%.c $(GEN_OPTS) | $(GEN_FILES) $(GEN_MISC_FILES)
	@echo 'Arm Compiler - building file: "$<"'
	"/Applications/ti/ccs2100/ccs/tools/compiler/ti-cgt-armllvm_5.1.1.LTS/bin/tiarmclang" -c @"device.opt"  -march=thumbv6m -mcpu=cortex-m0plus -mfloat-abi=soft -mlittle-endian -mthumb -O2 -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/OLED" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/UWB" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/MOTOR" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/SYSTEM" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/Debug" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source/third_party/CMSIS/Core/Include" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source" -gdwarf-3 -Wall -MMD -MP -MF"$(basename $(<F)).d_raw" -MT"$(@)"  $(GEN_OPTS__FLAG) -o"$@" "$<"
	@echo 'Finished building: "$<"'
	@echo ' '

startup_mspm0g350x_ticlang.o: /Applications/ti/mspm0_sdk_2_10_00_04/source/ti/devices/msp/m0p/startup_system_files/ticlang/startup_mspm0g350x_ticlang.c $(GEN_OPTS) | $(GEN_FILES) $(GEN_MISC_FILES)
	@echo 'Arm Compiler - building file: "$<"'
	"/Applications/ti/ccs2100/ccs/tools/compiler/ti-cgt-armllvm_5.1.1.LTS/bin/tiarmclang" -c @"device.opt"  -march=thumbv6m -mcpu=cortex-m0plus -mfloat-abi=soft -mlittle-endian -mthumb -O2 -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/OLED" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/UWB" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/MOTOR" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/SYSTEM" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/Debug" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source/third_party/CMSIS/Core/Include" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source" -gdwarf-3 -Wall -MMD -MP -MF"$(basename $(<F)).d_raw" -MT"$(@)"  $(GEN_OPTS__FLAG) -o"$@" "$<"
	@echo 'Finished building: "$<"'
	@echo ' '


