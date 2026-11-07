package dev.flowforge.model;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonValue;

import java.util.Arrays;
import java.util.Optional;

/** Node shapes supported by the DSL. */
public enum NodeType {
    START("start"),
    END("end"),
    STEP("step"),
    DECIDE("decide"),
    DB("db"),
    DOC("doc"),
    NOTE("note");

    private final String keyword;

    NodeType(String keyword) { this.keyword = keyword; }

    @JsonValue
    public String keyword() { return keyword; }

    public static Optional<NodeType> fromKeyword(String s) {
        return Arrays.stream(values()).filter(t -> t.keyword.equals(s)).findFirst();
    }

    @JsonCreator
    public static NodeType parse(String s) {
        return fromKeyword(s).orElseThrow(() -> new IllegalArgumentException("unknown node type '" + s + "'"));
    }

    /** start/end nodes may omit their id; the keyword becomes the id. */
    public boolean keywordIsDefaultId() { return this == START || this == END; }
}
