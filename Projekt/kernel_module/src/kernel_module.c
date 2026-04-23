#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/ioport.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/string.h>
#include <linux/ctype.h>
#include <linux/delay.h>
#include <linux/math64.h>

MODULE_INFO(intree, "Y");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Student SYKOM");
MODULE_DESCRIPTION("Floating-point multiplier procfs driver");
MODULE_VERSION("1.0");

#define SYKT_GPIO_BASE_ADDR   0x00100000
#define SYKT_GPIO_SIZE        0x8000
#define SYKT_EXIT             0x3333
#define SYKT_EXIT_CODE        0x7F

#define OFF_ARG1_H  0x100
#define OFF_ARG1_L  0x108
#define OFF_ARG2_H  0x0F0
#define OFF_ARG2_L  0x0F8
#define OFF_CTRL    0x0D0
#define OFF_STATUS  0x0E8
#define OFF_RES_H   0x0D8
#define OFF_RES_L   0x0E0

#define STATUS_BUSY          0x01
#define STATUS_DONE          0x02
#define STATUS_ERROR         0x04
#define STATUS_INVALID_ARG   0x08

#define EXP_BITS    27
#define MANT_BITS   36
#define EXP_BIAS    ((1ULL << (EXP_BITS-1)) - 1)
#define MANT_MASK   ((1ULL << MANT_BITS) - 1)
#define HIDDEN_BIT  (1ULL << MANT_BITS)

static void __iomem *baseptr;
static struct proc_dir_entry *proc_dir;
static struct proc_dir_entry *proc_a1, *proc_a2, *proc_ctrl, *proc_stat, *proc_res;

static int parse_scientific(const char *buf, u64 *val)
{
    const char *p = buf;
    int sign = 0;
    u64 mant = 0;
    int exp10 = 0;
    int frac_digits = 0;

    while (isspace(*p)) p++;
    if (*p == '-') { sign = 1; p++; }
    else if (*p == '+') p++;

    if (!isdigit(*p)) return -EINVAL;
    while (isdigit(*p)) {
        mant = mant * 10 + (*p - '0');
        p++;
    }
    if (*p == '.') {
        p++;
        while (isdigit(*p)) {
            mant = mant * 10 + (*p - '0');
            frac_digits++;
            p++;
        }
    }

    if (*p == 'e' || *p == 'E') {
        int exp_sign = 1;
        p++;
        if (*p == '-') { exp_sign = -1; p++; }
        else if (*p == '+') p++;
        if (!isdigit(*p)) return -EINVAL;
        exp10 = 0;
        while (isdigit(*p)) {
            exp10 = exp10 * 10 + (*p - '0');
            p++;
        }
        exp10 *= exp_sign;
    }

    while (isspace(*p)) p++;
    if (*p != '\0') return -EINVAL;

    exp10 -= frac_digits;
    if (mant == 0) {
        *val = 0;
        return 0;
    }

    int e2 = (exp10 << 1) + exp10;  // 3 * exp10

    u64 m = mant;
    int shift = 0;
    if (m >= (HIDDEN_BIT << 1)) {
        m >>= 1;
        shift = 1;
    } else if (m < HIDDEN_BIT) {
        m <<= 1;
        shift = -1;
    }
    e2 += shift;

    int exp_final = e2 + EXP_BIAS;
    if (exp_final <= 0) { *val = 0; return 0; }
    if (exp_final >= (1 << EXP_BITS)) {
        exp_final = (1 << EXP_BITS) - 1;
        m = 0;
    }

    m &= MANT_MASK;
    *val = ((u64)sign << 63) | ((u64)exp_final << MANT_BITS) | m;
    return 0;
}

static int format_scientific(u64 val, char *buf, size_t len)
{
    if (val == 0) return snprintf(buf, len, "0.0");

    int sign   = (val >> 63) & 1;
    int exp    = (val >> MANT_BITS) & ((1 << EXP_BITS)-1);
    u64 mant   = val & MANT_MASK;

    if (exp == 0 || exp == (1<<EXP_BITS)-1) {
        if (mant == 0) return snprintf(buf, len, "%sinf", sign ? "-" : "");
        else return snprintf(buf, len, "nan");
    }

    mant |= HIDDEN_BIT;
    int e2 = exp - EXP_BIAS;
    u64 m = mant;
    int e10 = 0;

    while (e2 > 0) {
        if (m > (U64_MAX / 2)) { m = div_u64(m + 5, 10); e10++; }
        m <<= 1;
        e2--;
    }
    while (e2 < 0) {
        m = (m + 1) >> 1;
        e2++;
    }

    while (m >= 10) { m = div_u64(m + 5, 10); e10++; }

    return snprintf(buf, len, "%s%llu.0e%d", sign ? "-" : "", m, e10);
}

static ssize_t a1stma_write(struct file *f, const char __user *ubuf, size_t c, loff_t *pos)
{
    char kbuf[64];
    u64 val;
    if (c >= sizeof(kbuf)) return -EINVAL;
    if (copy_from_user(kbuf, ubuf, c)) return -EFAULT;
    kbuf[c] = '\0';
    if (parse_scientific(kbuf, &val)) return -EINVAL;
    writel(val >> 32, baseptr + OFF_ARG1_H);
    writel(val & 0xFFFFFFFF, baseptr + OFF_ARG1_L);
    return c;
}

static ssize_t a2stma_write(struct file *f, const char __user *ubuf, size_t c, loff_t *pos)
{
    char kbuf[64];
    u64 val;
    if (c >= sizeof(kbuf)) return -EINVAL;
    if (copy_from_user(kbuf, ubuf, c)) return -EFAULT;
    kbuf[c] = '\0';
    if (parse_scientific(kbuf, &val)) return -EINVAL;
    writel(val >> 32, baseptr + OFF_ARG2_H);
    writel(val & 0xFFFFFFFF, baseptr + OFF_ARG2_L);
    return c;
}

static ssize_t ctstma_write(struct file *f, const char __user *ubuf, size_t c, loff_t *pos)
{
    char kbuf[8];
    u32 cmd;
    if (c >= sizeof(kbuf)) return -EINVAL;
    if (copy_from_user(kbuf, ubuf, c)) return -EFAULT;
    kbuf[c] = '\0';
    if (kstrtou32(kbuf, 10, &cmd)) return -EINVAL;
    if (cmd == 1) {
        u32 st = readl(baseptr + OFF_STATUS);
        if (!(st & STATUS_BUSY))
            writel(1, baseptr + OFF_CTRL);
    }
    return c;
}

static ssize_t ststma_read(struct file *f, char __user *ubuf, size_t c, loff_t *pos)
{
    u32 st = readl(baseptr + OFF_STATUS);
    const char *msg;
    if (st & STATUS_BUSY)           msg = "busy\n";
    else if (st & STATUS_DONE)      msg = "done\n";
    else if (st & STATUS_ERROR)     msg = "error\n";
    else                            msg = "idle\n";
    return simple_read_from_buffer(ubuf, c, pos, msg, strlen(msg));
}

static ssize_t restma_read(struct file *f, char __user *ubuf, size_t c, loff_t *pos)
{
    char buf[64];
    u32 st = readl(baseptr + OFF_STATUS);
    int len;
    if (!(st & STATUS_DONE)) {
        len = snprintf(buf, sizeof(buf), "not ready\n");
    } else {
        u32 hi = readl(baseptr + OFF_RES_H);
        u32 lo = readl(baseptr + OFF_RES_L);
        u64 val = ((u64)hi << 32) | lo;
        len = format_scientific(val, buf, sizeof(buf));
        buf[len++] = '\n';
        buf[len] = '\0';
    }
    return simple_read_from_buffer(ubuf, c, pos, buf, len);
}

static const struct file_operations a1_fops = { .write = a1stma_write };
static const struct file_operations a2_fops = { .write = a2stma_write };
static const struct file_operations ctrl_fops= { .write = ctstma_write };
static const struct file_operations stat_fops = { .read  = ststma_read };
static const struct file_operations res_fops  = { .read  = restma_read };

static int __init sykom_init(void)
{
    baseptr = ioremap(SYKT_GPIO_BASE_ADDR, SYKT_GPIO_SIZE);
    if (!baseptr) return -ENOMEM;

    proc_dir = proc_mkdir("sykom", NULL);
    if (!proc_dir) { iounmap(baseptr); return -ENOMEM; }

    proc_a1   = proc_create("a1stma", 0220, proc_dir, &a1_fops);
    proc_a2   = proc_create("a2stma", 0220, proc_dir, &a2_fops);
    proc_ctrl = proc_create("ctstma", 0220, proc_dir, &ctrl_fops);
    proc_stat = proc_create("ststma", 0444, proc_dir, &stat_fops);
    proc_res  = proc_create("restma", 0444, proc_dir, &res_fops);

    if (!proc_a1 || !proc_a2 || !proc_ctrl || !proc_stat || !proc_res) {
        pr_err("Failed to create proc entries\n");
        remove_proc_entry("a1stma", proc_dir);
        remove_proc_entry("a2stma", proc_dir);
        remove_proc_entry("ctstma", proc_dir);
        remove_proc_entry("ststma", proc_dir);
        remove_proc_entry("restma", proc_dir);
        remove_proc_entry("sykom", NULL);
        iounmap(baseptr);
        return -ENOMEM;
    }

    pr_info("SYKOM multiplier procfs module loaded\n");
    return 0;
}

static void __exit sykom_cleanup(void)
{
    writel(SYKT_EXIT | ((SYKT_EXIT_CODE) << 16), baseptr);
    remove_proc_entry("a1stma", proc_dir);
    remove_proc_entry("a2stma", proc_dir);
    remove_proc_entry("ctstma", proc_dir);
    remove_proc_entry("ststma", proc_dir);
    remove_proc_entry("restma", proc_dir);
    remove_proc_entry("sykom", NULL);
    iounmap(baseptr);
    pr_info("SYKOM multiplier module unloaded\n");
}

module_init(sykom_init);
module_exit(sykom_cleanup);