extern void qemu_init(int argc, char **argv);
extern int qemu_main_loop(void);
extern void qemu_cleanup(void);

int main(int argc, char **argv) {
    qemu_init(argc, argv);
    int status = qemu_main_loop();
    qemu_cleanup();
    return status;
}
