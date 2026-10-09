import unittest

from desk_review_plan import (
    load_request, make_plan, structural_boundaries, synthesis, formatted_token_count)


def count(messages):
    return sum(len(message["content"]) for message in messages)


class ReviewPlanTests(unittest.TestCase):
    def test_tokenizer_mapping_is_not_mistaken_for_two_tokens(self):
        class Tokenizer:
            def apply_chat_template(self, messages, **kwargs):
                self.kwargs = kwargs
                return {"input_ids": [1] * 20367, "attention_mask": [1] * 20367}
        tokenizer = Tokenizer()
        self.assertEqual(formatted_token_count(tokenizer, []), 20367)
        self.assertFalse(tokenizer.kwargs["return_dict"])
        self.assertTrue(tokenizer.kwargs["enable_thinking"])
        self.assertEqual(formatted_token_count(tokenizer, [], thinking=False), 20367)
        self.assertFalse(tokenizer.kwargs["enable_thinking"])

    def test_unexpected_tokenizer_shape_fails_closed(self):
        class Tokenizer:
            def apply_chat_template(self, messages, **kwargs):
                return [[1, 2]]
        with self.assertRaises(ValueError):
            formatted_token_count(Tokenizer(), [])

    def test_whole_source_and_budget(self):
        text = "int first() { return 1; }\nint last() { return first(); }\n"
        plan = make_plan(text, "fixture.cpp", "review", 4096, 512, count)
        self.assertEqual(len(plan["chunks"]), 1)
        self.assertIn("1: int first() { return 1; }\n2: int last() { return first(); }\n",
                      plan["chunks"][0]["messages"][1]["content"])
        self.assertEqual(plan["chunks"][0]["end"], 2)
        self.assertLessEqual(plan["chunks"][0]["prompt_tokens"] + 512 + 1024, 4096)

    def test_complete_structural_partition(self):
        text = "namespace fixture {\n" + "".join(
            f"int f{i}() {{\n" + ("  // fixture evidence\n" * 22) + f"  return {i};\n}}\n"
            for i in range(8)
        ) + "}\n"
        plan = make_plan(text, "fixture.cpp", "review", 4096, 512, count)
        self.assertGreater(len(plan["chunks"]), 1)
        first = 1
        reconstructed = ""
        lines = text.splitlines(keepends=True)
        for chunk in plan["chunks"]:
            self.assertEqual(chunk["start"], first)
            self.assertLessEqual(chunk["prompt_tokens"] + 512 + 1024, 4096)
            reconstructed += "".join(lines[chunk["start"] - 1:chunk["end"]])
            content = chunk["messages"][1]["content"]
            numbered = content.split("BEGIN UNTRUSTED SOURCE\n", 1)[1].rsplit("\nEND UNTRUSTED SOURCE", 1)[0]
            delivered = "".join(line.split(": ", 1)[1] for line in numbered.splitlines(keepends=True))
            self.assertEqual(delivered, "".join(lines[chunk["start"] - 1:chunk["end"]]))
            self.assertTrue(numbered.startswith(f"{chunk['start']}: "))
            first = chunk["end"] + 1
            self.assertEqual(chunk["split"], "structural")
        self.assertEqual(reconstructed, text)
        self.assertEqual(first, len(lines) + 1)

    def test_comments_strings_and_raw_literals_do_not_split_functions(self):
        text = 'namespace x {\nint f() {\n // }\n auto s=R"tag(})tag";\n return 0;\n}\n}\n'
        self.assertEqual(structural_boundaries(text), [6, 7])

    def test_oversized_unit_explicit_line_fallback(self):
        text = "int f() {\n" + (" int x = 1;\n" * 600) + "}\n"
        chunks = make_plan(text, "large.cpp", "review", 4096, 512, count)["chunks"]
        self.assertGreater(len(chunks), 1)
        self.assertEqual(chunks[0]["split"], "oversized-unit-lines")
        self.assertEqual(chunks[-1]["end"], 602)

    def test_numbering_preserves_blank_lines_crlf_and_unterminated_last_line(self):
        text = "\r\n// comment\r\n\r\nint last;"
        plan = make_plan(text, "fixture.cpp", "review", 4096, 512, count)
        self.assertIn("1: \r\n2: // comment\r\n3: \r\n4: int last;",
                      plan["chunks"][0]["messages"][1]["content"])
        self.assertEqual(plan["lines"], 4)

    def test_oversized_line_and_invalid_input_fail_loudly(self):
        for text in ("x" * 5000, "", "binary\0"):
            with self.assertRaises(ValueError):
                make_plan(text, "fixture.cpp", "", 4096, 512, count)
        with self.assertRaises(ValueError):
            make_plan("source", "fixture.cpp", "", 4096, 8192, count)

    def test_utf8_request_keeps_source_punctuation(self):
        raw = b'{"text":"' + "a\u2192b\u2014c".encode("utf-8") + b'"}'
        self.assertNotIn(b"\x1a", raw)
        self.assertEqual(load_request(raw)["text"], "a\u2192b\u2014c")

    def test_synthesis_keeps_cross_part_evidence_and_task(self):
        messages = synthesis("race analysis", "fixture.cpp", ["Lines 1-10: writer", "Lines 11-20: reader"], "declarations")
        self.assertIn("cross-part", messages[1]["content"])
        self.assertIn("writer", messages[1]["content"])
        self.assertIn("reader", messages[1]["content"])
        self.assertIn("race analysis", messages[1]["content"])
        self.assertIn("untrusted", messages[0]["content"])


if __name__ == "__main__":
    unittest.main()
