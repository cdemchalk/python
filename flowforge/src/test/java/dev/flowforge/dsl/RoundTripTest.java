package dev.flowforge.dsl;

import dev.flowforge.model.Diagram;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

class RoundTripTest {
    static final String MESSY = """
            #! FlowForge round-trip sample
            title   "Messy  spacing"
            direction LR

              start "Go"   #blue    #! keep me
            step a "Line one\\nLine two"
            decide d "Ok?" #f80
            a -> d   -.-> end : "has #! inside"
            d==>a:retry
            group core "Core" {
              a,   d   #! inside
            }
            lane l "Lane" {start}
            @pos a 10,20.5
            """;

    @Test
    void untouchedDocumentIsByteIdentical() {
        for (String text : List.of(MESSY, MESSY.replace("\n", "\r\n"), MESSY.stripTrailing(), "", "\n\n",
                FlowParserTest.SPEC)) {
            assertEquals(text, FlowWriter.write(FlowParser.parse(text)));
        }
    }

    @Test
    void examplesRoundTrip() throws IOException {
        Path dir = Path.of("examples");
        try (Stream<Path> files = Files.list(dir)) {
            for (Path p : files.filter(f -> f.toString().endsWith(".flow")).toList()) {
                String text = Files.readString(p);
                assertEquals(text, FlowWriter.write(FlowParser.parse(text)), p.toString());
            }
        }
    }

    @Test
    void regeneratedStatementsParseToTheSameDiagram() {
        FlowDocument doc = FlowParser.parse(MESSY);
        FlowDocument dirty = doc.withEntries(doc.entries().stream()
                .map(e -> e.stmt() instanceof Stmt.Blank ? e : e.replace(e.stmt())).toList());
        String regenerated = FlowWriter.write(dirty);
        assertNotEquals(MESSY, regenerated);
        assertTrue(regenerated.contains("start \"Go\" #blue  #! keep me"), regenerated);
        assertTrue(regenerated.contains("  start"), "indent kept");
        assertEquals(doc.toDiagram(), FlowParser.parse(regenerated).toDiagram());
        // regenerating twice is stable
        FlowDocument again = FlowParser.parse(regenerated);
        FlowDocument dirty2 = again.withEntries(again.entries().stream().map(e -> e.replace(e.stmt())).toList());
        assertEquals(regenerated, FlowWriter.write(dirty2));
    }

    @Test
    void canonicalDocumentFromDiagram() {
        Diagram d = FlowParser.parse(MESSY).toDiagram();
        String canonical = FlowWriter.write(FlowWriter.fromDiagram(d));
        assertEquals(d, FlowParser.parse(canonical).toDiagram());
        assertTrue(canonical.startsWith("title Messy  spacing\ndirection LR\n"), canonical);
    }

    @Test
    void renderQuotesOnlyWhenNeeded() {
        assertEquals("a -> b : yes", FlowWriter.render(Stmt.EdgeChain.single("a", "b",
                dev.flowforge.model.EdgeStyle.SOLID, "yes")));
        assertEquals("a -.-> b : \" padded \"", FlowWriter.render(Stmt.EdgeChain.single("a", "b",
                dev.flowforge.model.EdgeStyle.DASHED, " padded ")));
        assertEquals("@pos a 1.5,-2", FlowWriter.render(new Stmt.PosDecl("a", 1.5, -2)));
    }
}
