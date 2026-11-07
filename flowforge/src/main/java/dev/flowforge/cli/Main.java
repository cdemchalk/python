package dev.flowforge.cli;

import dev.flowforge.dsl.FlowDocument;
import dev.flowforge.dsl.FlowParseException;
import dev.flowforge.dsl.FlowParser;
import dev.flowforge.layout.LayoutEngine;
import dev.flowforge.layout.LayoutResult;
import dev.flowforge.model.Diagram;
import dev.flowforge.render.SvgRenderer;
import dev.flowforge.render.Theme;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** {@code flowforge <command> ...}. Exit codes: 0 ok, 1 lint findings, 2 usage or input errors. */
public final class Main {
    static final String USAGE = """
            FlowForge - text-to-diagram tool

            usage: flowforge <command> [args]

              render <file.flow> [-o out.svg|out.png] [--theme light|dark] [--scale 2]
              serve  <file.flow> [--port 7070] [--theme light|dark]
              add-node <file> <id> "<label>" [--type step] [--after <id>] [--color blue]
              connect  <file> <from> <to> [--label yes] [--style solid|dashed|thick]
              disconnect <file> <from> <to>
              remove   <file> <id>
              rename   <file> <id> "<new label>"
              move     <file> <id> <x> <y>        pin a node (writes @pos)
              tidy     <file> [<id>]              clear manual positions
              validate <file> [--json]            orphans, unreachable nodes, decisions with < 2 exits
              export-json <file> [-o out.json]
              import-json <file.json> [-o out.flow]
            """;

    private final PrintStream out, err;

    Main(PrintStream out, PrintStream err) {
        this.out = out;
        this.err = err;
    }

    public static void main(String[] args) {
        System.exit(new Main(System.out, System.err).run(args));
    }

    /** Parsed arguments: positionals plus --options. */
    record Args(List<String> pos, Map<String, String> opt) {
        String opt(String name, String def) { return opt.getOrDefault(name, def); }

        static Args parse(String[] a, int from, Set<String> flags) {
            List<String> pos = new ArrayList<>();
            Map<String, String> opt = new HashMap<>();
            for (int i = from; i < a.length; i++) {
                String s = a[i];
                if (s.startsWith("--") && s.length() > 2) {
                    String k = s.substring(2);
                    int eq = k.indexOf('=');
                    if (eq >= 0) opt.put(k.substring(0, eq), k.substring(eq + 1));
                    else if (flags.contains(k)) opt.put(k, "true");
                    else if (i + 1 < a.length) opt.put(k, a[++i]);
                    else throw new UsageException("option --" + k + " needs a value");
                } else if (s.equals("-o")) {
                    if (i + 1 >= a.length) throw new UsageException("-o needs a file name");
                    opt.put("o", a[++i]);
                } else {
                    pos.add(s);
                }
            }
            return new Args(pos, opt);
        }

        String need(int i, String what) {
            if (i >= pos.size()) throw new UsageException("missing " + what);
            return pos.get(i);
        }
    }

    static final class UsageException extends RuntimeException {
        UsageException(String m) { super(m); }
    }

    /** An error already reported to the user. */
    static final class Failure extends RuntimeException {
        final int code;

        Failure(int code) {
            super(null, null, false, false);
            this.code = code;
        }
    }

    int run(String[] args) {
        if (args.length == 0 || Set.of("-h", "--help", "help").contains(args[0])) {
            out.print(USAGE);
            return args.length == 0 ? 2 : 0;
        }
        try {
            return switch (args[0]) {
                case "render" -> render(Args.parse(args, 1, Set.of()));
                default -> Commands.run(this, args[0], args);
            };
        } catch (UsageException e) {
            err.println("error: " + e.getMessage());
            err.println("run 'flowforge help' for usage");
            return 2;
        } catch (Failure f) {
            return f.code;
        } catch (IOException e) {
            err.println("error: " + e.getMessage());
            return 2;
        } catch (IllegalArgumentException e) {
            err.println("error: " + e.getMessage());
            return 2;
        }
    }

    PrintStream out() { return out; }

    PrintStream err() { return err; }

    // ------------------------------------------------------------------ shared helpers

    static String read(Path p) throws IOException {
        if (!Files.exists(p)) throw new UsageException("file not found: " + p);
        return Files.readString(p, StandardCharsets.UTF_8);
    }

    FlowDocument load(Path p) throws IOException {
        String text = read(p);
        try {
            return FlowParser.parse(text);
        } catch (FlowParseException e) {
            err.println(e.format(p.toString()));
            throw new Failure(2);
        }
    }

    static void writeAtomically(Path p, String content) throws IOException {
        Path abs = p.toAbsolutePath();
        Path tmp = abs.resolveSibling("." + abs.getFileName() + ".tmp");
        Files.writeString(tmp, content, StandardCharsets.UTF_8);
        try {
            Files.move(tmp, abs, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                    java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        } catch (java.nio.file.AtomicMoveNotSupportedException e) {
            Files.move(tmp, abs, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
    }

    static Theme theme(Args a, Diagram d) {
        return Theme.byName(a.opt("theme", d.theme() == null ? "light" : d.theme()));
    }

    // ------------------------------------------------------------------ render

    int render(Args a) throws IOException {
        Path in = Path.of(a.need(0, "input file"));
        Diagram d = load(in).toDiagram();
        Theme theme = theme(a, d);
        String o = a.opt("o", replaceExt(in, ".svg").toString());
        LayoutResult lr = new LayoutEngine().layout(d);
        if (o.equals("-")) {
            out.print(SvgRenderer.render(lr, theme));
            return 0;
        }
        Path outPath = Path.of(o);
        String lower = o.toLowerCase(java.util.Locale.ROOT);
        if (lower.endsWith(".png")) {
            double scale = Double.parseDouble(a.opt("scale", "2"));
            dev.flowforge.render.PngRenderer.write(lr, theme, scale, outPath);
        } else if (lower.endsWith(".svg")) {
            Files.writeString(outPath, SvgRenderer.render(lr, theme), StandardCharsets.UTF_8);
        } else {
            throw new UsageException("output must end in .svg or .png: " + o);
        }
        out.println("wrote " + outPath);
        return 0;
    }

    static Path replaceExt(Path p, String ext) {
        String name = p.getFileName().toString();
        int dot = name.lastIndexOf('.');
        return p.resolveSibling((dot > 0 ? name.substring(0, dot) : name) + ext);
    }
}
