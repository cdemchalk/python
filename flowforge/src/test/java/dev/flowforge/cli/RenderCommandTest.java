package dev.flowforge.cli;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

class RenderCommandTest {
    @TempDir
    Path dir;

    final ByteArrayOutputStream out = new ByteArrayOutputStream(), err = new ByteArrayOutputStream();

    int run(String... args) { return new Main(new PrintStream(out), new PrintStream(err)).run(args); }

    @Test
    void rendersSvgNextToTheInput() throws Exception {
        Path f = dir.resolve("x.flow");
        Files.writeString(f, "a -> b\n");
        assertEquals(0, run("render", f.toString()));
        assertTrue(Files.readString(dir.resolve("x.svg")).startsWith("<svg"));
    }

    @Test
    void rendersToExplicitOutputWithTheme() throws Exception {
        Path f = dir.resolve("x.flow");
        Files.writeString(f, "a -> b\n");
        Path o = dir.resolve("out/y.svg");
        Files.createDirectories(o.getParent());
        assertEquals(0, run("render", f.toString(), "-o", o.toString(), "--theme", "dark"));
        assertTrue(Files.readString(o).contains("data-theme=\"dark\""));
    }

    @Test
    void parseErrorsAreReportedWithLocation() throws Exception {
        Path f = dir.resolve("bad.flow");
        Files.writeString(f, "a -> b\nstep c \"oops\n");
        assertEquals(2, run("render", f.toString()));
        assertTrue(err.toString().contains("bad.flow:2:8: error: unterminated string"), err.toString());
    }

    @Test
    void usageErrors() {
        assertEquals(2, run("render"));
        assertTrue(err.toString().contains("missing input file"));
        assertEquals(2, run("frobnicate"));
        assertEquals(2, run("render", dir.resolve("nope.flow").toString()));
    }

    @Test
    void stdoutOutput() throws Exception {
        Path f = dir.resolve("x.flow");
        Files.writeString(f, "a -> b\n");
        assertEquals(0, run("render", f.toString(), "-o", "-"));
        assertTrue(out.toString().startsWith("<svg"));
    }
}
