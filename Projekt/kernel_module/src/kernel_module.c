#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/ioport.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/string.h>
#include <linux/ctype.h>
#include <linux/delay.h>
#include <linux/slab.h>

MODULE_INFO(intree, "Y");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Student SYKOM");
MODULE_DESCRIPTION("Floating-point multiplier procfs driver for SYKOM project");
MODULE_VERSION("1.0");

/* Adresy bazowe */
#define SYKT_GPIO_BASE_ADDR   0x00100000
#define SYKT_GPIO_SIZE        0x8000
#define SYKT_EXIT             0x3333
#define SYKT_EXIT_CODE        0x7F

/* Adresy rejestrów - zgodne ze specyfikacją */
#define OFF_ARG1_H  0x100   /* Argument 1 - część starsza */
#define OFF_ARG1_L  0x108   /* Argument 1 - część młodsza */
#define OFF_ARG2_H  0xFC0   /* Argument 2 - część starsza */
#define OFF_ARG2_L  0xFC8   /* Argument 2 - część młodsza */
#define OFF_CTRL    0xDC0   /* Rejestr sterujący */
#define OFF_STATUS  0xEC8   /* Rejestr stanu */
#define OFF_RES_H   0xDC8   /* Wynik - część starsza */
#define OFF_RES_L   0xEC0   /* Wynik - część młodsza */

/* Statusy */
#define STATUS_BUSY          0x01
#define STATUS_DONE          0x02
#define STATUS_ERROR         0x04
#define STATUS_INVALID_ARG   0x08

/* Definicje formatu liczby zmiennoprzecinkowej */
#define EXP_BITS    27
#define MANT_BITS   36
#define EXP_BIAS    ((1ULL << (EXP_BITS - 1)) - 1)  /* 67,108,863 */
#define MANT_MASK   ((1ULL << MANT_BITS) - 1)       /* 36-bitowa maska */
#define HIDDEN_BIT  (1ULL << MANT_BITS)             /* Bit 36 */

static void __iomem *baseptr;
static struct proc_dir_entry *proc_dir;
static struct proc_dir_entry *proc_a1, *proc_a2, *proc_ctrl, *proc_stat, *proc_res;

/* Funkcja pomocnicza do logowania debugowania */
#define DEBUG_PRINT(fmt, ...) pr_debug("SYKOM: " fmt, ##__VA_ARGS__)

/*
 * Konwersja stringa w formacie naukowym (np. "1.5e2", "-2.3E-4", "0.0")
 * na 64-bitową liczbę zmiennoprzecinkową w formacie sprzętowym.
 * Format sprzętowy:
 *   bit 63: znak (1 = ujemna)
 *   bity 62..36: wykładnik (27 bitów, bias = 67,108,863)
 *   bity 35..0: mantysa (36 bitów)
 */
static int parse_scientific(const char *buf, u64 *val)
{
    const char *p = buf;
    int sign = 0;
    u64 mantissa = 0;
    int exponent_base10 = 0;
    int fractional_digits = 0;
    int digit_count = 0;

    /* Pomijamy białe znaki */
    while (isspace(*p)) p++;

    /* Znak liczby */
    if (*p == '-') {
        sign = 1;
        p++;
    } else if (*p == '+') {
        p++;
    }

    /* Sprawdzamy czy jest cyfra (lub kropka) */
    if (!isdigit(*p) && *p != '.') {
        return -EINVAL;
    }

    /* Część całkowita */
    while (isdigit(*p)) {
        if (digit_count < 18) { /* Zabezpieczenie przed overflow */
            mantissa = mantissa * 10 + (*p - '0');
        }
        digit_count++;
        p++;
    }

    /* Część ułamkowa */
    if (*p == '.') {
        p++;
        while (isdigit(*p)) {
            if (digit_count < 18) {
                mantissa = mantissa * 10 + (*p - '0');
            }
            fractional_digits++;
            digit_count++;
            p++;
        }
    }

    /* Jeśli nie było żadnych cyfr - błąd */
    if (digit_count == 0) {
        return -EINVAL;
    }

    /* Wykładnik (opcjonalny) */
    if (*p == 'e' || *p == 'E') {
        int exp_sign = 1;
        p++;
        if (*p == '-') {
            exp_sign = -1;
            p++;
        } else if (*p == '+') {
            p++;
        }
        
        if (!isdigit(*p)) {
            return -EINVAL;
        }
        
        exponent_base10 = 0;
        while (isdigit(*p)) {
            exponent_base10 = exponent_base10 * 10 + (*p - '0');
            p++;
        }
        exponent_base10 *= exp_sign;
    }

    /* Pomijamy końcowe białe znaki */
    while (isspace(*p)) p++;

    /* Sprawdzamy czy dotarliśmy do końca stringa */
    if (*p != '\0' && *p != '\n') {
        return -EINVAL;
    }

    /* Korekta wykładnika o cyfry ułamkowe */
    exponent_base10 -= fractional_digits;

    /* Obsługa zera */
    if (mantissa == 0) {
        *val = 0;
        return 0;
    }

    /*
     * Konwersja do formatu sprzętowego.
     * Algorytm:
     * 1. Przybliżenie: wykładnik_binarny ≈ wykładnik_dziesiętny * log2(10) ≈ exp10 * 3.321928
     * 2. Normalizacja mantysy do postaci 1.xxxxx * 2^exp2
     */
    
    /* Używamy przybliżenia: mnożymy przez 3321928 i dzielimy przez 1000000 */
    u64 m = mantissa;
    int exp2 = 0;
    
    /* Przybliżona konwersja wykładnika z podstawy 10 na 2 */
    int exp2_adjust = (exponent_base10 * 3321928LL) / 1000000;
    
    /* Normalizacja mantysy - doprowadzamy do postaci 1.xxx * 2^exp2 */
    if (m > 0) {
        /* Najpierw przesuwamy w lewo aby wykorzystać precyzję */
        while (m < HIDDEN_BIT && m > 0) {
            m <<= 1;
            exp2--;
        }
        
        /* Potem przesuwamy w prawo jeśli trzeba */
        while (m >= (HIDDEN_BIT << 1)) {
            m >>= 1;
            exp2++;
        }
    }

    /* Dodajemy korektę wykładnika */
    exp2 += exp2_adjust;

    /* Aplikujemy bias */
    int exp_final = exp2 + EXP_BIAS;

    /* Sprawdzamy zakres wykładnika */
    if (exp_final <= 0) {
        /* Underflow - zwracamy zero */
        *val = 0;
        return 0;
    }
    
    if (exp_final >= (1 << EXP_BITS)) {
        /* Overflow - zwracamy nieskończoność */
        exp_final = (1 << EXP_BITS) - 1;
        m = 0;
    }

    /* Usuwamy ukryty bit i maskujemy mantysę */
    m &= MANT_MASK;

    /* Składamy liczbę */
    *val = ((u64)sign << 63) | ((u64)exp_final << MANT_BITS) | m;
    
    return 0;
}

/*
 * Konwersja 64-bitowej liczby zmiennoprzecinkowej na string w formacie naukowym.
 * Format wyjściowy: [znak]mantysa.0e[wykładnik]
 * np. "1.5e2", "-2.3e4", "0.0"
 */
static int format_scientific(u64 val, char *buf, size_t len)
{
    if (val == 0) {
        return snprintf(buf, len, "0.0");
    }

    int sign = (val >> 63) & 1;
    int exp = (val >> MANT_BITS) & ((1 << EXP_BITS) - 1);
    u64 mant = val & MANT_MASK;

    /* Obsługa wartości specjalnych */
    if (exp == 0) {
        /* Zero zdemoralizowane */
        return snprintf(buf, len, "0.0");
    }
    
    if (exp == (1 << EXP_BITS) - 1) {
        /* Nieskończoność lub NaN */
        if (mant == 0) {
            return snprintf(buf, len, "%sinf", sign ? "-" : "+");
        } else {
            return snprintf(buf, len, "nan");
        }
    }

    /* Dodajemy ukryty bit */
    mant |= HIDDEN_BIT;
    
    /* Obliczamy rzeczywisty wykładnik binarny */
    int exp2 = exp - EXP_BIAS;
    
    /*
     * Konwersja na format dziesiętny.
     * Przybliżenie: wykładnik_dziesiętny ≈ wykładnik_binarny * log10(2) ≈ exp2 * 0.30103
     * Ponieważ to tylko przybliżenie, wynik może nie być idealnie dokładny,
     * ale powinien być czytelny dla użytkownika.
     */
    
    /* Używamy uproszczonej metody - wypisujemy mantysę i przybliżony wykładnik */
    u64 integer_part = mant;
    int exp10 = 0;

    /* Przybliżona konwersja */
    exp10 = (exp2 * 30103) / 100000; /* exp2 * log10(2) ≈ exp2 * 0.30103 */

    /* Normalizacja do postaci dziesiętnej */
    while (integer_part >= 10) {
        integer_part = div_u64(integer_part + 5, 10); /* Zaokrąglanie */
        exp10++;
    }

    /* Formatowanie wyniku */
    return snprintf(buf, len, "%s%llu.0e%d", 
                   sign ? "-" : "", 
                   integer_part, 
                   exp10);
}

/*
 * Walidacja i zapis argumentu 1
 */
static ssize_t a1stma_write(struct file *filp, const char __user *user_buf, 
                            size_t count, loff_t *pos)
{
    char kbuf[64];
    u64 val;
    int ret;

    if (count >= sizeof(kbuf)) {
        pr_err("SYKOM: a1stma buffer overflow\n");
        return -EINVAL;
    }

    if (copy_from_user(kbuf, user_buf, count)) {
        return -EFAULT;
    }
    kbuf[count] = '\0';

    /* Usuwamy znak nowej linii jeśli istnieje */
    char *newline = strchr(kbuf, '\n');
    if (newline) *newline = '\0';

    ret = parse_scientific(kbuf, &val);
    if (ret) {
        pr_err("SYKOM: Invalid format for a1stma: %s\n", kbuf);
        return -EINVAL;
    }

    pr_debug("SYKOM: Writing arg1 = 0x%016llx\n", val);
    writel(val >> 32, baseptr + OFF_ARG1_H);
    writel(val & 0xFFFFFFFF, baseptr + OFF_ARG1_L);

    return count;
}

/*
 * Walidacja i zapis argumentu 2
 */
static ssize_t a2stma_write(struct file *filp, const char __user *user_buf,
                            size_t count, loff_t *pos)
{
    char kbuf[64];
    u64 val;
    int ret;

    if (count >= sizeof(kbuf)) {
        pr_err("SYKOM: a2stma buffer overflow\n");
        return -EINVAL;
    }

    if (copy_from_user(kbuf, user_buf, count)) {
        return -EFAULT;
    }
    kbuf[count] = '\0';

    /* Usuwamy znak nowej linii jeśli istnieje */
    char *newline = strchr(kbuf, '\n');
    if (newline) *newline = '\0';

    ret = parse_scientific(kbuf, &val);
    if (ret) {
        pr_err("SYKOM: Invalid format for a2stma: %s\n", kbuf);
        return -EINVAL;
    }

    pr_debug("SYKOM: Writing arg2 = 0x%016llx\n", val);
    writel(val >> 32, baseptr + OFF_ARG2_H);
    writel(val & 0xFFFFFFFF, baseptr + OFF_ARG2_L);

    return count;
}

/*
 * Zapis do rejestru sterującego.
 * Wartość "1" uruchamia obliczenia.
 */
static ssize_t ctstma_write(struct file *filp, const char __user *user_buf,
                            size_t count, loff_t *pos)
{
    char kbuf[16];
    u32 cmd;
    int ret;

    if (count >= sizeof(kbuf)) {
        pr_err("SYKOM: ctstma buffer overflow\n");
        return -EINVAL;
    }

    if (copy_from_user(kbuf, user_buf, count)) {
        return -EFAULT;
    }
    kbuf[count] = '\0';

    /* Usuwamy znak nowej linii */
    char *newline = strchr(kbuf, '\n');
    if (newline) *newline = '\0';

    ret = kstrtou32(kbuf, 10, &cmd);
    if (ret) {
        pr_err("SYKOM: Invalid control value: %s\n", kbuf);
        return -EINVAL;
    }

    pr_debug("SYKOM: Control command: %u\n", cmd);

    if (cmd == 1) {
        /* Sprawdzamy czy sprzęt nie jest zajęty */
        u32 status = readl(baseptr + OFF_STATUS);
        if (status & STATUS_BUSY) {
            pr_err("SYKOM: Hardware is busy\n");
            return -EBUSY;
        }

        /* Uruchamiamy obliczenia - zapis 1 do rejestru sterującego */
        writel(1, baseptr + OFF_CTRL);
        
        /* Krótkie opóźnienie na wykonanie obliczeń */
        udelay(10);
        
        pr_debug("SYKOM: Multiplication started\n");
    } else if (cmd == 0) {
        /* Zatrzymanie/reset */
        writel(0, baseptr + OFF_CTRL);
        pr_debug("SYKOM: Control reset\n");
    } else {
        pr_err("SYKOM: Unknown control command: %u (use 0 or 1)\n", cmd);
        return -EINVAL;
    }

    return count;
}

/*
 * Odczyt statusu operacji.
 * Format: "idle", "busy", "done", "error"
 */
static ssize_t ststma_read(struct file *filp, char __user *user_buf,
                           size_t count, loff_t *pos)
{
    u32 status = readl(baseptr + OFF_STATUS);
    const char *msg;
    size_t msg_len;

    pr_debug("SYKOM: Status register: 0x%08x\n", status);

    if (status & STATUS_ERROR) {
        if (status & STATUS_INVALID_ARG) {
            msg = "error: invalid argument\n";
        } else {
            msg = "error\n";
        }
    } else if (status & STATUS_DONE) {
        msg = "done\n";
    } else if (status & STATUS_BUSY) {
        msg = "busy\n";
    } else {
        msg = "idle\n";
    }

    msg_len = strlen(msg);
    return simple_read_from_buffer(user_buf, count, pos, msg, msg_len);
}

/*
 * Odczyt wyniku.
 * Format: liczba w notacji naukowej dziesiętnej (np. "7.5e0")
 */
static ssize_t restma_read(struct file *filp, char __user *user_buf,
                           size_t count, loff_t *pos)
{
    char buf[64];
    int len;
    u32 status = readl(baseptr + OFF_STATUS);

    if (!(status & STATUS_DONE)) {
        if (status & STATUS_BUSY) {
            len = snprintf(buf, sizeof(buf), "busy\n");
        } else if (status & STATUS_ERROR) {
            len = snprintf(buf, sizeof(buf), "error\n");
        } else {
            len = snprintf(buf, sizeof(buf), "idle\n");
        }
    } else {
        u32 hi = readl(baseptr + OFF_RES_H);
        u32 lo = readl(baseptr + OFF_RES_L);
        u64 val = ((u64)hi << 32) | lo;

        pr_debug("SYKOM: Result = 0x%016llx (hi=0x%08x, lo=0x%08x)\n", 
                 val, hi, lo);

        len = format_scientific(val, buf, sizeof(buf) - 1);
        if (len >= sizeof(buf) - 1) {
            len = sizeof(buf) - 2;
        }
        buf[len++] = '\n';
        buf[len] = '\0';
    }

    return simple_read_from_buffer(user_buf, count, pos, buf, len);
}

/* Struktury file_operations dla procfs */
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

/*
 * Inicjalizacja modułu
 */
static int __init sykom_init(void)
{
    pr_info("SYKOM: Initializing floating-point multiplier module\n");

    /* Mapowanie pamięci I/O */
    baseptr = ioremap(SYKT_GPIO_BASE_ADDR, SYKT_GPIO_SIZE);
    if (!baseptr) {
        pr_err("SYKOM: Failed to map I/O memory\n");
        return -ENOMEM;
    }
    pr_debug("SYKOM: Mapped I/O memory at 0x%p\n", baseptr);

    /* Tworzenie katalogu /proc/sykom */
    proc_dir = proc_mkdir("sykom", NULL);
    if (!proc_dir) {
        pr_err("SYKOM: Failed to create /proc/sykom directory\n");
        iounmap(baseptr);
        return -ENOMEM;
    }

    /* Tworzenie plików procfs */
    proc_a1 = proc_create("a1stma", 0220, proc_dir, &a1_fops);
    proc_a2 = proc_create("a2stma", 0220, proc_dir, &a2_fops);
    proc_ctrl = proc_create("ctstma", 0220, proc_dir, &ctrl_fops);
    proc_stat = proc_create("ststma", 0444, proc_dir, &stat_fops);
    proc_res = proc_create("restma", 0444, proc_dir, &res_fops);

    /* Sprawdzanie czy wszystkie pliki zostały utworzone */
    if (!proc_a1 || !proc_a2 || !proc_ctrl || !proc_stat || !proc_res) {
        pr_err("SYKOM: Failed to create one or more proc entries\n");
        
        /* Czyszczenie w przypadku błędu */
        if (proc_a1) proc_remove(proc_a1);
        if (proc_a2) proc_remove(proc_a2);
        if (proc_ctrl) proc_remove(proc_ctrl);
        if (proc_stat) proc_remove(proc_stat);
        if (proc_res) proc_remove(proc_res);
        
        remove_proc_entry("sykom", NULL);
        iounmap(baseptr);
        return -ENOMEM;
    }

    /* Inicjalizacja sprzętu - zerowanie rejestru sterującego */
    writel(0, baseptr + OFF_CTRL);
    
    pr_info("SYKOM: Module loaded successfully\n");
    pr_info("SYKOM: Proc files available at /proc/sykom/\n");
    pr_info("SYKOM: Usage:\n");
    pr_info("  echo '2.5' > /proc/sykom/a1stma\n");
    pr_info("  echo '3.0' > /proc/sykom/a2stma\n");
    pr_info("  echo 1 > /proc/sykom/ctstma\n");
    pr_info("  cat /proc/sykom/ststma\n");
    pr_info("  cat /proc/sykom/restma\n");
    
    return 0;
}

/*
 * Czyszczenie modułu
 */
static void __exit sykom_cleanup(void)
{
    pr_info("SYKOM: Cleaning up module\n");

    /* Sygnalizacja zakończenia pracy emulatora */
    writel(SYKT_EXIT | ((SYKT_EXIT_CODE) << 16), baseptr);

    /* Usuwanie plików procfs */
    if (proc_a1) proc_remove(proc_a1);
    if (proc_a2) proc_remove(proc_a2);
    if (proc_ctrl) proc_remove(proc_ctrl);
    if (proc_stat) proc_remove(proc_stat);
    if (proc_res) proc_remove(proc_res);
    
    /* Usuwanie katalogu */
    remove_proc_entry("sykom", NULL);

    /* Odmapowanie pamięci I/O */
    if (baseptr) {
        iounmap(baseptr);
    }

    pr_info("SYKOM: Module unloaded\n");
}

module_init(sykom_init);
module_exit(sykom_cleanup);