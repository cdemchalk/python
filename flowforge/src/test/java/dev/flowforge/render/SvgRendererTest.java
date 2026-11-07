package dev.flowforge.render;

import dev.flowforge.dsl.FlowParser;
import org.junit.jupiter.api.Test;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

import javax.xml.parsers.DocumentBuilderFactory;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.*;

class SvgRendererTest {
    static Document xml(String svg) throws Exception {
        return DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(new ByteArrayInputStream(svg.getBytes(StandardCharsets.UTF_8)));
    }

    @Test
    void producesWellFormedSvgWithEditableElements() throws Exception {
        String svg = SvgRenderer.render(FlowParser.parse("""
                title A <&> "B"
                start "Go & see"
                decide d "Ok?" #amber
                db store
                start -> d -> store : "yes <sure>"
                d -.-> start
                group "G" #blue { d, store }
                """).toDiagram(), Theme.light());
        Document doc = xml(svg);
        Element root = doc.getDocumentElement();
        assertEquals("svg", root.getTagName());
        NodeList gs = doc.getElementsByTagName("g");
        int nodes = 0, edges = 0, labels = 0;
        for (int i = 0; i < gs.getLength(); i++) {
            String cls = ((Element) gs.item(i)).getAttribute("class");
            if (cls.startsWith("ff-node ")) nodes++;
            if (cls.equals("ff-edge")) edges++;
            if (cls.equals("ff-edge-label")) labels++;
        }
        assertEquals(3, nodes);
        assertEquals(3, edges);
        assertEquals(2, labels, "a chain label applies to each edge of the chain");
        assertTrue(svg.contains("data-id=\"store\""));
        assertTrue(svg.contains("stroke-dasharray=\"6 5\""), "dashed edge");
        assertTrue(svg.contains("Go &amp; see"));
        assertTrue(svg.contains("#fff3d6"), "amber fill");
    }

    @Test
    void darkThemeChangesColors() {
        var d = FlowParser.parse("a -> b").toDiagram();
        String light = SvgRenderer.render(d, Theme.light());
        String dark = SvgRenderer.render(d, Theme.dark());
        assertTrue(light.contains("fill=\"#ffffff\""));
        assertTrue(dark.contains("fill=\"#0f141a\""));
        assertTrue(dark.contains("data-theme=\"dark\""));
    }

    @Test
    void hexColorsAreTinted() {
        Theme.Swatch s = Theme.light().swatch("f80", dev.flowforge.model.NodeType.STEP);
        assertEquals("#ff8800", s.stroke());
        assertNotEquals("#ff8800", s.fill());
    }

    @Test
    void multilineLabelsBecomeTspans() {
        String svg = SvgRenderer.render(FlowParser.parse("step a \"one\\ntwo\"").toDiagram(), Theme.light());
        assertTrue(svg.contains(">one</tspan>"));
        assertTrue(svg.contains(">two</tspan>"));
    }
}
