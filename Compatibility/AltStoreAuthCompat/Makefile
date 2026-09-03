ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AltStoreAuthCompat

AltStoreAuthCompat_FILES = Tweak.m
AltStoreAuthCompat_CFLAGS = -fobjc-arc -Wall -Wextra -Werror
AltStoreAuthCompat_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
