################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Each subdirectory must supply rules for building sources it contributes
HARDWARE/UWB/%.o: ../HARDWARE/UWB/%.c $(GEN_OPTS) | $(GEN_FILES) $(GEN_MISC_FILES)
	@echo 'Arm Compiler - building file: "$<"'
	"/Applications/ti/ccs2100/ccs/tools/compiler/ti-cgt-armllvm_5.1.1.LTS/bin/tiarmclang" -c @"device.opt"  -march=thumbv6m -mcpu=cortex-m0plus -mfloat-abi=soft -mlittle-endian -mthumb -O2 -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/OLED" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/UWB" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE/MOTOR" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/HARDWARE" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/SYSTEM" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0" -I"/Users/sherlockdarwin/workspace_ccstheia/MinecraftDog_mspm0/Debug" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source/third_party/CMSIS/Core/Include" -I"/Applications/ti/mspm0_sdk_2_10_00_04/source" -gdwarf-3 -Wall -MMD -MP -MF"HARDWARE/UWB/$(basename $(<F)).d_raw" -MT"$(@)"  $(GEN_OPTS__FLAG) -o"$@" "$<"
	@echo 'Finished building: "$<"'
	@echo ' '


