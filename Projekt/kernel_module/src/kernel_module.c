#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/ioport.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/ctype.h>
#include <linux/delay.h>
#include <linux/math64.h>
#include <linux/fs.h>

MODULE_INFO(intree, "Y");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Student SYKOM");
MODULE_DESCRIPTION("GPIO EMU multiplier procfs driver");
MODULE_VERSION("1.0");

#define SYKT_GPIO_BASE_ADDR   0x00100000
#define SYKT_GPIO_SIZE        0x8000
#define SYKT_EXIT             0x3333
#define SYKT_EXIT_CODE        0x7F

#define REG_ARG1_H    0x100
#define REG_ARG1_L    0x108
#define REG_ARG2_H    0x0F0
#define REG_ARG2_L    0x0F8
#define REG_CTRL      0x0D0
#define REG_STATUS    0x0E8
#define REG_RESULT_H  0x0D8
#define REG_RESULT_L  0x0E0
#define REG_FINISHER  0x0000

#define STATUS_BUSY         0x01
#define STATUS_DONE         0x02
#define STATUS_ERROR        0x04
#define STATUS_INVALID_ARG  0x08

#define EXP_BITS          27
#define MANT_BITS         36
#define EXP_BIAS          ((1ULL << (EXP_BITS - 1)) - 1)
#define MANT_MASK         ((1ULL << MANT_BITS) - 1)
#define HIDDEN_BIT        (1ULL << MANT_BITS)

static void __iomem *baseptr;
static struct proc_dir_entry *proc_dir;
static struct proc_dir_entry *proc_a1, *proc_a2, *proc_res, *proc_stat, *proc_ctrl;

// ----------------------------------------------------------------------
// Konwersja stringu naukowego na 64-bitowy format zmiennoprzecinkowy
// ----------------------------------------------------------------------
static int parse_scientific(const char *str, u64 *val)
{
    int sign = 0;
    u64 mantissa = 0;
    int exponent = 0;
    int frac_digits = 0;
    int exp_sign = 1;
    const char *p = str;

    while (isspace(*p)) p++;

    if (*p == '-') { sign = 1; p++; }
    else if (*p == '+') { p++; }

    if (!isdigit(*p)) return -EINVAL;

    while (isdigit(*p)) {
        mantissa = mantissa * 10 + (*p - '0');
        p++;
    }

    if (*p == '.') {
        p++;
        while (isdigit(*p)) {
            mantissa = mantissa * 10 + (*p - '0');
            frac_digits++;
            p++;
            if (frac_digits > 20) break;
        }
    }

    if (*p == 'e' || *p == 'E') {
        p++;
        if (*p == '-') { exp_sign = -1; p++; }
        else if (*p == '+') { p++; }
        if (!isdigit(*p)) return -EINVAL;
        exponent = 0;
        while (isdigit(*p)) {
            exponent = exponent * 10 + (*p - '0');
            p++;
        }
        exponent *= exp_sign;
    }

    while (isspace(*p)) p++;
    if (*p != '\0') return -EINVAL;

    exponent -= frac_digits;

    if (mantissa == 0) {
        *val = 0;
        return 0;
    }

    int bin_exp = 0;
    u64 mant = mantissa;
    int dec_exp = exponent;

    while (dec_exp > 0) {
        if (mant > (U64_MAX / 10)) {
            mant >>= 1;
            bin_exp++;
        }
        mant *= 10;
        dec_exp--;
    }
    while (dec_exp < 0) {
        mant = div_u64(mant + 5, 10);
        dec_exp++;
    }

    while (mant >= (HIDDEN_BIT << 1)) {
        mant >>= 1;
        bin_exp++;
    }
    while (mant < HIDDEN_BIT) {
        mant <<= 1;
        bin_exp--;
    }

    int final_exp = bin_exp + EXP_BIAS;
    if (final_exp <= 0) {
        *val = 0;
        return 0;
    }
    if (final_exp >= (1 << EXP_BITS)) {
        final_exp = (1 << EXP_BITS) - 1;
        mant = 0;
    }

    mant &= MANT_MASK;
    *val = ((u64)sign << 63) | ((u64)final_exp << MANT_BITS) | mant;
    return 0;
}

// ----------------------------------------------------------------------
// Konwersja 64-bitowego formatu na string naukowy
// ----------------------------------------------------------------------
static int format_scientific(u64 val, char *buf, size_t len)
{
    if (val == 0) {
        snprintf(buf, len, "0.0");
        return 0;
    }

    int sign = (val >> 63) & 1;
    int exp = (val >> MANT_BITS) & ((1 << EXP_BITS) - 1);
    u64 mant = val & MANT_MASK;

    if (exp == 0) {
        if (mant == 0) {
            snprintf(buf, len, "0.0");
            return 0;
        }
    }
    if (exp == (1 << EXP_BITS) - 1) {
        if (mant == 0)
            snprintf(buf, len, "%sinf", sign ? "-" : "");
        else
            snprintf(buf, len, "nan");
        return 0;
    }

    mant |= HIDDEN_BIT;
    int bin_exp = exp - EXP_BIAS;
    u64 dec_mant = mant;
    int dec_exp = 0;

    while (bin_exp > 0) {
        if (dec_mant > (U64_MAX / 2)) {
            dec_mant = div_u64(dec_mant + 5, 10);
            dec_exp++;
        }
        dec_mant <<= 1;
        bin_exp--;
    }
    while (bin_exp < 0) {
        dec_mant = div_u64(dec_mant + 1, 2);
        bin_exp++;
    }

    while (dec_mant >= 10) {
        dec_mant = div_u64(dec_mant + 5, 10);
        dec_exp++;
    }

    char fmt_buf[64];
    if (sign) {
        snprintf(fmt_buf, sizeof(fmt_buf), "-%llu.0e%d", dec_mant, dec_exp);
    } else {
        snprintf(fmt_buf, sizeof(fmt_buf), "%llu.0e%d", dec_mant, dec_exp);
    }

    snprintf(buf, len, "%s", fmt_buf);
    return 0;
}

// ----------------------------------------------------------------------
// PROC FS: a1stma – zapis pierwszego argumentu
// ----------------------------------------------------------------------
static ssize_t a1stma_write(struct file *filp, const char __user *ubuf,
                            size_t count, loff_t *ppos)
{
    char kbuf[64];
    u64 val;
    if (count >= sizeof(kbuf)) return -EINVAL;
    if (copy_from_user(kbuf, ubuf, count)) return -EFAULT;
    kbuf[count] = '\0';
    if (parse_scientific(kbuf, &val)) return -EINVAL;
    writel(val >> 32, baseptr + REG_ARG1_H);
    writel(val & 0xFFFFFFFF, baseptr + REG_ARG1_L);
    return count;
}

// ----------------------------------------------------------------------
// PROC FS: a2stma – zapis drugiego argumentu
// ----------------------------------------------------------------------
static ssize_t a2stma_write(struct file *filp, const char __user *ubuf,
                            size_t count, loff_t *ppos)
{
    char kbuf[64];
    u64 val;
    if (count >= sizeof(kbuf)) return -EINVAL;
    if (copy_from_user(kbuf, ubuf, count)) return -EFAULT;
    kbuf[count] = '\0';
    if (parse_scientific(kbuf, &val)) return -EINVAL;
    writel(val >> 32, baseptr + REG_ARG2_H);
    writel(val & 0xFFFFFFFF, baseptr + REG_ARG2_L);
    return count;
}

// ----------------------------------------------------------------------
// PROC FS: ctstma – sterowanie (1 = start mnożenia)
// ----------------------------------------------------------------------
static ssize_t ctstma_write(struct file *filp, const char __user *ubuf,
                            size_t count, loff_t *ppos)
{
    char kbuf[8];
    u32 cmd;
    if (count >= sizeof(kbuf)) return -EINVAL;
    if (copy_from_user(kbuf, ubuf, count)) return -EFAULT;
    kbuf[count] = '\0';
    if (kstrtou32(kbuf, 10, &cmd)) return -EINVAL;
    if (cmd == 1) {
        u32 stat = readl(baseptr + REG_STATUS);
        if (!(stat & STATUS_BUSY)) {
            writel(1, baseptr + REG_CTRL);
        }
    }
    return count;
}

// ----------------------------------------------------------------------
// PROC FS: ststma – odczyt statusu
// ----------------------------------------------------------------------
static ssize_t ststma_read(struct file *filp, char __user *ubuf,
                           size_t count, loff_t *ppos)
{
    char buf[32];
    u32 stat = readl(baseptr + REG_STATUS);
    int len;
    if (stat & STATUS_BUSY)
        len = snprintf(buf, sizeof(buf), "busy\n");
    else if (stat & STATUS_DONE)
        len = snprintf(buf, sizeof(buf), "done\n");
    else if (stat & STATUS_ERROR)
        len = snprintf(buf, sizeof(buf), "error\n");
    else
        len = snprintf(buf, sizeof(buf), "idle\n");
    return simple_read_from_buffer(ubuf, count, ppos, buf, len);
}

// ----------------------------------------------------------------------
// PROC FS: restma – odczyt wyniku
// ----------------------------------------------------------------------
static ssize_t restma_read(struct file *filp, char __user *ubuf,
                           size_t count, loff_t *ppos)
{
    char buf[64];
    u32 stat = readl(baseptr + REG_STATUS);
    int len;
    if (!(stat & STATUS_DONE)) {
        len = snprintf(buf, sizeof(buf), "not ready\n");
    } else {
        u32 hi = readl(baseptr + REG_RESULT_H);
        u32 lo = readl(baseptr + REG_RESULT_L);
        u64 val = ((u64)hi << 32) | lo;
        format_scientific(val, buf, sizeof(buf));
        len = strlen(buf);
        buf[len++] = '\n';
        buf[len] = '\0';
    }
    return simple_read_from_buffer(ubuf, count, ppos, buf, len);
}

// ----------------------------------------------------------------------
// Struktury file_operations dla procfs (starsze API jądra)
// ----------------------------------------------------------------------
static const struct file_operations a1_ops = {
    .write = a1stma_write,
};
static const struct file_operations a2_ops = {
    .write = a2stma_write,
};
static const struct file_operations ctrl_ops = {
    .write = ctstma_write,
};
static const struct file_operations STATUS_ops = {
    .read = ststma_read,
};
static const struct file_operations res_ops = {
    .read = restma_read,
};

// ----------------------------------------------------------------------
// Inicjalizacja modułu
// ----------------------------------------------------------------------
static int __init my_init_module(void)
{
    printk(KERN_INFO "SYCOM GPIO EMU multiplier module loaded\n");

    baseptr = ioremap(SYKT_GPIO_BASE_ADDR, SYKT_GPIO_SIZE);
    if (!baseptr) {
        printk(KERN_ERR "Failed to ioremap GPIO EMU\n");
        return -ENOMEM;
    }

    proc_dir = proc_mkdir("sykom", NULL);
    if (!proc_dir) {
        iounmap(baseptr);
        return -ENOMEM;
    }

    proc_a1   = proc_create("a1stma", 0220, proc_dir, &a1_ops);
    proc_a2   = proc_create("a2stma", 0220, proc_dir, &a2_ops);
    proc_ctrl = proc_create("ctstma", 0220, proc_dir, &ctrl_ops);
    proc_stat = proc_create("ststma", 0444, proc_dir, &STATUS_ops);
    proc_res  = proc_create("restma",  0444, proc_dir, &res_ops);

    if (!proc_a1 || !proc_a2 || !proc_ctrl || !proc_stat || !proc_res) {
        printk(KERN_ERR "Failed to create proc entries\n");
        remove_proc_entry("a1stma", proc_dir);
        remove_proc_entry("a2stma", proc_dir);
        remove_proc_entry("ctstma", proc_dir);
        remove_proc_entry("ststma", proc_dir);
        remove_proc_entry("restma", proc_dir);
        remove_proc_entry("sykom", NULL);
        iounmap(baseptr);
        return -ENOMEM;
    }

    return 0;
}

// ----------------------------------------------------------------------
// Sprzątanie modułu
// ----------------------------------------------------------------------
static void __exit my_cleanup_module(void)
{
    printk(KERN_INFO "SYCOM GPIO EMU multiplier module unloaded\n");
    writel(SYKT_EXIT | ((SYKT_EXIT_CODE) << 16), baseptr + REG_FINISHER);
    remove_proc_entry("a1stma", proc_dir);
    remove_proc_entry("a2stma", proc_dir);
    remove_proc_entry("ctstma", proc_dir);
    remove_proc_entry("ststma", proc_dir);
    remove_proc_entry("restma", proc_dir);
    remove_proc_entry("sykom", NULL);
    iounmap(baseptr);
}

module_init(my_init_module);
module_exit(my_cleanup_module);