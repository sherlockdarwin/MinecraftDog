################################################################################
# Automatically-generated file. Do not edit!
# Toolchain: GNU Tools for STM32 (14.3.rel1)
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
C_SRCS += \
../HARDWARE/STEPPER/stepper.c \
../HARDWARE/STEPPER/tail.c 

OBJS += \
./HARDWARE/STEPPER/stepper.o \
./HARDWARE/STEPPER/tail.o 

C_DEPS += \
./HARDWARE/STEPPER/stepper.d \
./HARDWARE/STEPPER/tail.d 


# Each subdirectory must supply rules for building sources it contributes
HARDWARE/STEPPER/%.o HARDWARE/STEPPER/%.su HARDWARE/STEPPER/%.cyclo: ../HARDWARE/STEPPER/%.c HARDWARE/STEPPER/subdir.mk
	arm-none-eabi-gcc "$<" -mcpu=cortex-m3 -std=gnu11 -g3 -DDEBUG -DUSE_HAL_DRIVER -DSTM32F103xE -c -I../Core/Inc -I../Drivers/STM32F1xx_HAL_Driver/Inc -I../Drivers/STM32F1xx_HAL_Driver/Inc/Legacy -I../Drivers/CMSIS/Device/ST/STM32F1xx/Include -I../Drivers/CMSIS/Include -I../ -I../SYSTEM -I../HARDWARE -I../HARDWARE/MOTOR -I../HARDWARE/UWB -O0 -ffunction-sections -fdata-sections -Wall -fstack-usage -fcyclomatic-complexity -MMD -MP -MF"$(@:%.o=%.d)" -MT"$@" --specs=nano.specs -mfloat-abi=soft -mthumb -o "$@"

clean: clean-HARDWARE-2f-STEPPER

clean-HARDWARE-2f-STEPPER:
	-$(RM) ./HARDWARE/STEPPER/stepper.cyclo ./HARDWARE/STEPPER/stepper.d ./HARDWARE/STEPPER/stepper.o ./HARDWARE/STEPPER/stepper.su ./HARDWARE/STEPPER/tail.cyclo ./HARDWARE/STEPPER/tail.d ./HARDWARE/STEPPER/tail.o ./HARDWARE/STEPPER/tail.su

.PHONY: clean-HARDWARE-2f-STEPPER

