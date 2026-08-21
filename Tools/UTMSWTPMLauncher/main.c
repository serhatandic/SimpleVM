extern int swtpm_main(
    int argc,
    char **argv,
    const char *program_name,
    const char *interface_name
);

int main(int argc, char **argv) {
    return swtpm_main(argc, argv, "swtpm", "socket");
}
