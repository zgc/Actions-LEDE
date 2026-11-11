define KernelPackage/hid-logitech
  SUBMENU:=Input modules
  TITLE:=Logitech HID++ receiver support
  DEPENDS:=+kmod-hid +kmod-hid-generic +kmod-usb-hid
  KCONFIG:=CONFIG_HID_LOGITECH=m CONFIG_HID_LOGITECH_DJ=m CONFIG_HID_LOGITECH_HIDPP=m
  FILES:= \
	$(LINUX_DIR)/drivers/hid/hid-logitech.ko \
	$(LINUX_DIR)/drivers/hid/hid-lg-g15.ko \
	$(LINUX_DIR)/drivers/hid/hid-logitech-dj.ko \
	$(LINUX_DIR)/drivers/hid/hid-logitech-hidpp.ko
  AUTOLOAD:=$(call AutoLoad,61,hid-logitech hid-logitech-dj hid-logitech-hidpp,1)
endef

define KernelPackage/hid-logitech/description
 Logitech USB/Bolt receiver and HID++ device support.
endef

$(eval $(call KernelPackage,hid-logitech))
