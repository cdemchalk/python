package dev.flowforge.render;

import dev.flowforge.layout.LayoutResult;

import java.io.IOException;
import java.nio.file.Path;

/** PNG export (phase 5). */
public final class PngRenderer {
    private PngRenderer() {}

    public static void write(LayoutResult r, Theme t, double scale, Path out) throws IOException {
        throw new IllegalArgumentException("PNG export is not implemented yet");
    }
}
