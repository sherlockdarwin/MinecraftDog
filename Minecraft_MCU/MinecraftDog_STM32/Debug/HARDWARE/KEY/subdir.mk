################################################################################
# Automatically-generated file. Do not edit!
# Toolchain: GNU Tools for STM32 (14.3.rel1)
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
C_SRCS += \
../HARDWARE/KEY/key.c 

OBJS += \
./HARDWARE/KEY/key.o 

C_DEPS += \
./HARDWARE/KEY/key.d 


# Each subdirectory must supply rules for building sources it contributes
HARDWARE/KEY/%.o HARDWARE/KEY/%.su HARDWARE/KEY/%.cyclo: ../HARDWARE/KEY/%.c HARDWARE/KEY/subdir.mk
	arm-none-eabi-gcc "$<" -mcpu=cortex-m3 -std=gnu11 -g3 -DDEBUG -DUSE_HAL_DRIVER -DSTM32F103xE -c -I../Core/Inc -I../Drivers/STM32F1xx_HAL_Driver/Inc -I../Drivers/STM32F1xx_HAL_Driver/Inc/Legacy -I../Drivers/CMSIS/Device/ST/STM32F1xx/Include -I../Drivers/CMSIS/Include -I../ -I../SYSTEM -I../HARDWARE -I../HARDWARE/MOTOR -I../HARDWARE/UWB -O0 -ffunction-sections -fdata-sections -Wall -fstack-usage -fcyclomatic-complexity -MMD -MP -MF"$(@:%.o=%.d)" -MT"$@" --specs=nano.specs -mfloat-abi=soft -mthumb -o "$@"

clean: clean-HARDWARE-2f-KEY

clean-HARDWARE-2f-KEY:
	-$(RM) ./HARDWARE/KEY/key.cyclo ./HARDWARE/KEY/key.d ./HARDWARE/KEY/key.o ./HARDWARE/KEY/key.su

.PHONY: clean-HARDWARE-2f-KEY

