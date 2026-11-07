package dev.flowforge.dsl;

import java.util.List;
import java.util.stream.Collectors;

public class FlowParseException extends RuntimeException {
    private final List<ParseError> errors;

    public FlowParseException(List<ParseError> errors) {
        super(errors.isEmpty() ? "parse error" : errors.get(0).line() + ":" + errors.get(0).column() + ": "
                + errors.get(0).message());
        this.errors = List.copyOf(errors);
    }

    public List<ParseError> errors() { return errors; }

    public String format(String fileName) {
        return errors.stream().map(e -> e.format(fileName)).collect(Collectors.joining("\n"));
    }
}
