package app

import "core:fmt"
import "core:encoding/csv"
import "core:os"
import "core:strings"

CSV_Document :: struct {
	path:          string,
	delimiter:     rune,
	rows:          [][]string,
	column_count:  int,
	error_message: string,
}

csv_detect_delimiter :: proc(input: string) -> rune {
	comma_count, semicolon_count: int
	in_quotes := false

	// The first record is enough for normal CSV files and avoids commas in
	// later free-form text fields influencing the delimiter choice.
	for i := 0; i < len(input); i += 1 {
		ch := input[i]
		if ch == '"' {
			if in_quotes && i+1 < len(input) && input[i+1] == '"' {
				i += 1
				continue
			}
			in_quotes = !in_quotes
			continue
		}
		if !in_quotes {
			switch ch {
			case ',':
				comma_count += 1
			case ';':
				semicolon_count += 1
			case '\n':
				return semicolon_count > comma_count ? ';' : ','
			}
		}
	}

	return semicolon_count > comma_count ? ';' : ','
}

csv_document_read :: proc(filename: string) -> CSV_Document {
	document := CSV_Document{
		path = filename,
		delimiter = ',',
	}

	data, read_err := os.read_entire_file(filename, context.temp_allocator)
	if read_err != nil {
		document.error_message = "Unable to read file"
		fmt.eprintfln("Unable to read CSV file %v. Error: %v", filename, read_err)
		return document
	}

	document.delimiter = csv_detect_delimiter(string(data))
	reader: csv.Reader
	reader.comma = document.delimiter
	csv.reader_init_with_string(&reader, string(data), context.allocator)
	defer csv.reader_destroy(&reader)
	rows, parse_err := csv.read_all(&reader, context.allocator)
	document.rows = rows
	if parse_err != nil {
		document.error_message = "CSV parsing failed"
		fmt.eprintfln("Unable to parse CSV file %v. Error: %v", filename, parse_err)
		return document
	}

	for row in document.rows {
		document.column_count = max(document.column_count, len(row))
	}
	return document
}

csv_document_exists :: proc(documents: []CSV_Document, filename: string) -> bool {
	for document in documents {
		if document.path == filename {
			return true
		}
	}
	return false
}

csv_documents_destroy :: proc(documents: []CSV_Document) {
	for document in documents {
		for row in document.rows {
			for field in row {
				delete(field)
			}
			delete(row)
		}
		delete(document.rows)
	}
}
