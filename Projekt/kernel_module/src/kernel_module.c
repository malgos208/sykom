#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/ioport.h>
#include <asm/errno.h>
#include <asm/io.h>

MODULE_INFO(intree, "Y");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Aleksander Pruszkowski");
MODULE_DESCRIPTION("Simple kernel module for SYKOM lecture");
MODULE_VERSION("0.01");

#define SYKT_GPIO_BASE_ADDR (0x00100000)
#define SYKT_GPIO_SIZE      (0x8000)
#define SYKT_EXIT           (0x3333)
#define SYKT_EXIT_CODE      (0x7F)

void __iomem *baseptr;

int my_init_module(void) {
    printk(KERN_INFO "Init my module.\n");
    // Mapowanie pamieci dla przyszlej komunikacji z Verilogiem
    baseptr = ioremap(SYKT_GPIO_BASE_ADDR, SYKT_GPIO_SIZE);
    return 0;
}

void my_cleanup_module(void) {
    printk(KERN_INFO "Cleanup my module.\n");
    // Wpisanie kodu wyjscia do rejestru sterującego emulatora
    writel(SYKT_EXIT | ((SYKT_EXIT_CODE) << 16), baseptr);
    iounmap(baseptr);
}

module_init(my_init_module);
module_exit(my_cleanup_module);
