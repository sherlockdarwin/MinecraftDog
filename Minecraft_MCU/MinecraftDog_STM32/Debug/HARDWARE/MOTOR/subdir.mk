################################################################################
# Automatically-generated file. Do not edit!
# Toolchain: GNU Tools for STM32 (14.3.rel1)
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
C_SRCS += \
../HARDWARE/MOTOR/encoder.c \
../HARDWARE/MOTOR/motor.c 

OBJS += \
./HARDWARE/MOTOR/encoder.o \
./HARDWARE/MOTOR/motor.o 

C_DEPS += \
./HARDWARE/MOTOR/encoder.d \
./HARDWARE/MOTOR/motor.d 


# Each subdirectory must supply rules for building sources it contributes
HARDWARE/MOTOR/%.o HARDWARE/MOTOR/%.su HARDWARE/MOTOR/%.cyclo: ../HARDWARE/MOTOR/%.c HARDWARE/MOTOR/subdir.mk
	arm-none-eabi-gcc "$<" -mcpu=cortex-m3 -std=gnu11 -g3 -DDEBUG -DUSE_HAL_DRIVER -DSTM32F103xE -c -I../Core/Inc -I../Drivers/STM32F1xx_HAL_Driver/Inc -I../Drivers/STM32F1xx_HAL_Driver/Inc/Legacy -I../Drivers/CMSIS/Device/ST/STM32F1xx/Include -I../Drivers/CMSIS/Include -I../ -I../SYSTEM -I../HARDWARE -I../HARDWARE/MOTOR -I../HARDWARE/UWB -O0 -ffunction-sections -fdata-sections -Wall -fstack-usage -fcyclomatic-complexity -MMD -MP -MF"$(@:%.o=%.d)" -MT"$@" --specs=nano.specs -mfloat-abi=soft -mthumb -o "$@"

clean: clean-HARDWARE-2f-MOTOR

clean-HARDWARE-2f-MOTOR:
	-$(RM) ./HARDWARE/MOTOR/encoder.cyclo ./HARDWARE/MOTOR/encoder.d ./HARDWARE/MOTOR/encoder.o ./HARDWARE/MOTOR/encoder.su ./HARDWARE/MOTOR/motor.cyclo ./HARDWARE/MOTOR/motor.d ./HARDWARE/MOTOR/motor.o ./HARDWARE/MOTOR/motor.su

.PHONY: clean-HARDWARE-2f-MOTOR

