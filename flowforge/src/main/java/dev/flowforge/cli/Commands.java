package dev.flowforge.cli;

/** Commands other than render (filled in by later phases). */
final class Commands {
    private Commands() {}

    static int run(Main m, String cmd, String[] args) throws java.io.IOException {
        throw new Main.UsageException("unknown command '" + cmd + "'");
    }
}
