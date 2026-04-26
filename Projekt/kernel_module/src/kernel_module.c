#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/ioport.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/string.h>
#include <linux/ctype.h>
#include <linux/delay.h>

MODULE_INFO(intree, "Y");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Student SYKOM");
MODULE_DESCRIPTION("Floating-point multiplier procfs driver for SYKOM project");
MODULE_VERSION("1.0");

#define SYKT_GPIO_BASE_ADDR   0x00100000
#define SYKT_GPIO_SIZE        0x8000
#define SYKT_EXIT             0x3333
#define SYKT_EXIT_CODE        0x7F

#define OFF_ARG1_H  0x100
#define OFF_ARG1_L  0x108
#define OFF_ARG2_H  0xFC0
#define OFF_ARG2_L  0xFC8
#define OFF_CTRL    0xDC0
#define OFF_STATUS  0xEC8
#define OFF_RES_H   0xDC8
#define OFF_RES_L   0xEC0

#define STATUS_BUSY          0x01
#define STATUS_DONE          0x02
#define STATUS_ERROR         0x04
#define STATUS_INVALID_ARG   0x08

#define EXP_BITS    27
#define MANT_BITS   36
#define EXP_BIAS    ((1ULL << (EXP_BITS - 1)) - 1)
#define MANT_MASK   ((1ULL << MANT_BITS) - 1)
#define HIDDEN_BIT  (1ULL << MANT_BITS)

static void __iomem *baseptr;
static struct proc_dir_entry *proc_dir;
static struct proc_dir_entry *proc_a1, *proc_a2, *proc_ctrl, *proc_stat, *proc_res;

/*
 * Konwersja stringa w formacie naukowym na format sprzętowy
 */
static int parse_scientific(const char *buf, u64 *val)
{
    const char *p = buf;
    int sign = 0;
    u64 mantissa = 0;
    int exp10 = 0;
    int frac_digits = 0;
    int total_digits = 0;

    while (isspace(*p)) p++;

    if (*p == '-') { sign = 1; p++; }
    else if (*p == '+') p++;

    if (!isdigit(*p) && *p != '.')
        return -EINVAL;

    while (isdigit(*p)) {
        if (total_digits < 18) {
            if (mantissa <= (U64_MAX / 10))
                mantissa = mantissa * 10 + (*p - '0');
        }
        total_digits++;
        p++;
    }

    if (*p == '.') {
        p++;
        while (isdigit(*p)) {
            if (total_digits < 18) {
                if (mantissa <= (U64_MAX / 10))
                    mantissa = mantissa * 10 + (*p - '0');
            }
            frac_digits++;
            total_digits++;
            p++;
        }
    }

    if (total_digits == 0)
        return -EINVAL;

    if (*p == 'e' || *p == 'E') {
        int es = 1;
        p++;
        if (*p == '-') { es = -1; p++; }
        else if (*p == '+') p++;
        
        if (!isdigit(*p))
            return -EINVAL;
        
        exp10 = 0;
        while (isdigit(*p)) {
            exp10 = exp10 * 10 + (*p - '0');
            p++;
        }
        exp10 *= es;
    }

    while (isspace(*p)) p++;
    if (*p != '\0' && *p != '\n')
        return -EINVAL;

    exp10 -= frac_digits;

    if (mantissa == 0) {
        *val = 0;
        return 0;
    }

    /* Konwersja do formatu sprzętowego */
    u64 m = mantissa;
    int exp2 = 0;

    /* Normalizacja mantysy */
    while (m >= (HIDDEN_BIT << 1)) {
        m >>= 1;
        exp2++;
    }
    while (m < HIDDEN_BIT && m > 0) {
        m <<= 1;
        exp2--;
    }

    /* Przybliżona konwersja exp10 -> exp2 */
    {
        int exp2_adjust = 0;
        int e10 = exp10;
        
        if (e10 > 0) {
            while (e10 > 0) {
                exp2_adjust += 3;  /* log2(10) ≈ 3.32, zaokrąglamy do 3 */
                e10--;
            }
        } else {
            while (e10 < 0) {
                exp2_adjust -= 3;
                e10++;
            }
        }
        exp2 += exp2_adjust;
    }

    int exp_final = exp2 + EXP_BIAS;

    if (exp_final <= 0) {
        *val = 0;
        return 0;
    }
    
    if (exp_final >= (1 << EXP_BITS)) {
        exp_final = (1 << EXP_BITS) - 1;
        m = 0;
    }

    m &= MANT_MASK;
    *val = ((u64)sign << 63) | ((u64)exp_final << MANT_BITS) | m;
    
    return 0;
}

/*
 * Formatowanie wyniku - prosta wersja bez dzielenia 64-bitowego
 */
static int format_scientific(u64 val, char *buf, size_t len)
{
    if (val == 0)
        return snprintf(buf, len, "0.0");

    int sign = (val >> 63) & 1;
    int exp = (val >> MANT_BITS) & ((1 << EXP_BITS) - 1);
    u64 mant = val & MANT_MASK;

    if (exp == 0)
        return snprintf(buf, len, "0.0");
    
    if (exp == (1 << EXP_BITS) - 1) {
        if (mant == 0)
            return snprintf(buf, len, "%sinf", sign ? "-" : "+");
        else
            return snprintf(buf, len, "nan");
    }

    mant |= HIDDEN_BIT;
    
    /* Prosty format szesnastkowy do debugowania */
    return snprintf(buf, len, "%s0x%llx", 
                   sign ? "-" : "+", 
                   mant);
}

static ssize_t a1stma_write(struct file *f, const char __user *ubuf, size_t c, loff_t *pos)
{
    char kbuf[64];
    u64 val;
    
    if (c >= sizeof(kbuf))
        return -EINVAL;
    if (copy_from_user(kbuf, ubuf, c))
        return -EFAULT;
    kbuf[c] = '\0';
    
    if (parse_scientific(kbuf, &val))
        return -EINVAL;
    
    pr_info("SYKOM: a1 = %s -> 0x%016llx\n", kbuf, val);
    writel(val >> 32, baseptr + OFF_ARG1_H);
    writel(val & 0xFFFFFFFF, baseptr + OFF_ARG1_L);
    return c;
}

static ssize_t a2stma_write(struct file *f, const char __user *ubuf, size_t c, loff_t *pos)
{
    char kbuf[64];
    u64 val;
    
    if (c >= sizeof(kbuf))
        return -EINVAL;
    if (copy_from_user(kbuf, ubuf, c))
        return -EFAULT;
    kbuf[c] = '\0';
    
    if (parse_scientific(kbuf, &val))
        return -EINVAL;
    
    pr_info("SYKOM: a2 = %s -> 0x%016llx\n", kbuf, val);
    writel(val >> 32, baseptr + OFF_ARG2_H);
    writel(val & 0xFFFFFFFF, baseptr + OFF_ARG2_L);
    return c;
}

static ssize_t ctstma_write(struct file *f, const char __user *ubuf, size_t c, loff_t *pos)
{
    char kbuf[16];
    u32 cmd;
    
    if (c >= sizeof(kbuf))
        return -EINVAL;
    if (copy_from_user(kbuf, ubuf, c))
        return -EFAULT;
    kbuf[c] = '\0';
    
    if (kstrtou32(kbuf, 10, &cmd))
        return -EINVAL;
    
    pr_info("SYKOM: ctrl = %u\n", cmd);
    
    if (cmd == 1) {
        writel(1, baseptr + OFF_CTRL);
        udelay(10);
    } else if (cmd == 0) {
        writel(0, baseptr + OFF_CTRL);
    }
    
    return c;
}

static ssize_t ststma_read(struct file *f, char __user *ubuf, size_t c, loff_t *pos)
{
    u32 st = readl(baseptr + OFF_STATUS);
    const char *msg = "idle\n";
    
    if (st & STATUS_DONE)       msg = "done\n";
    else if (st & STATUS_BUSY)  msg = "busy\n";
    else if (st & STATUS_ERROR) msg = "error\n";
    
    pr_info("SYKOM: status = 0x%08x -> %s", st, msg);
    
    return simple_read_from_buffer(ubuf, c, pos, msg, strlen(msg));
}

static ssize_t restma_read(struct file *f, char __user *ubuf, size_t c, loff_t *pos)
{
    char buf[64];
    int len;
    u32 st = readl(baseptr + OFF_STATUS);
    
    if (!(st & STATUS_DONE)) {
        if (st & STATUS_BUSY)
            len = snprintf(buf, sizeof(buf), "busy\n");
        else if (st & STATUS_ERROR)
            len = snprintf(buf, sizeof(buf), "error\n");
        else
            len = snprintf(buf, sizeof(buf), "idle\n");
    } else {
        u32 hi = readl(baseptr + OFF_RES_H);
        u32 lo = readl(baseptr + OFF_RES_L);
        u64 val = ((u64)hi << 32) | lo;
        len = format_scientific(val, buf, sizeof(buf));
        buf[len++] = '\n';
        buf[len] = '\0';
    }
    
    pr_info("SYKOM: result = %s", buf);
    
    return simple_read_from_buffer(ubuf, c, pos, buf, len);
}

static const struct file_operations a1_fops = {
    .owner = THIS_MODULE,
    .write = a1stma_write,
};

static const struct file_operations a2_fops = {
    .owner = THIS_MODULE,
    .write = a2stma_write,
};

static const struct file_operations ctrl_fops = {
    .owner = THIS_MODULE,
    .write = ctstma_write,
};

static const struct file_operations stat_fops = {
    .owner = THIS_MODULE,
    .read = ststma_read,
};

static const struct file_operations res_fops = {
    .owner = THIS_MODULE,
    .read = restma_read,
};

static int __init sykom_init(void)
{
    pr_info("SYKOM: Initializing module\n");
    
    baseptr = ioremap(SYKT_GPIO_BASE_ADDR, SYKT_GPIO_SIZE);
    if (!baseptr) {
        pr_err("SYKOM: ioremap failed\n");
        return -ENOMEM;
    }

    proc_dir = proc_mkdir("sykom", NULL);
    if (!proc_dir) {
        pr_err("SYKOM: proc_mkdir failed\n");
        iounmap(baseptr);
        return -ENOMEM;
    }

    proc_a1 = proc_create("a1stma", 0220, proc_dir, &a1_fops);
    proc_a2 = proc_create("a2stma", 0220, proc_dir, &a2_fops);
    proc_ctrl = proc_create("ctstma", 0220, proc_dir, &ctrl_fops);
    proc_stat = proc_create("ststma", 0444, proc_dir, &stat_fops);
    proc_res = proc_create("restma", 0444, proc_dir, &res_fops);

    if (!proc_a1 || !proc_a2 || !proc_ctrl || !proc_stat || !proc_res) {
        pr_err("SYKOM: proc_create failed\n");
        remove_proc_entry("a1stma", proc_dir);
        remove_proc_entry("a2stma", proc_dir);
        remove_proc_entry("ctstma", proc_dir);
        remove_proc_entry("ststma", proc_dir);
        remove_proc_entry("restma", proc_dir);
        remove_proc_entry("sykom", NULL);
        iounmap(baseptr);
        return -ENOMEM;
    }

    writel(0, baseptr + OFF_CTRL);
    pr_info("SYKOM: Module loaded successfully\n");
    return 0;
}

static void __exit sykom_cleanup(void)
{
    pr_info("SYKOM: Cleaning up\n");
    writel(SYKT_EXIT | ((SYKT_EXIT_CODE) << 16), baseptr);
    remove_proc_entry("a1stma", proc_dir);
    remove_proc_entry("a2stma", proc_dir);
    remove_proc_entry("ctstma", proc_dir);
    remove_proc_entry("ststma", proc_dir);
    remove_proc_entry("restma", proc_dir);
    remove_proc_entry("sykom", NULL);
    iounmap(baseptr);
    pr_info("SYKOM: Module unloaded\n");
}

module_init(sykom_init);
module_exit(sykom_cleanup);