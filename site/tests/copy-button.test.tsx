import { afterEach, beforeEach, expect, jest, mock, test } from "bun:test";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
} from "@testing-library/react";
import { evaluate } from "@mdx-js/mdx";
import * as runtime from "react/jsx-runtime";
import rehypePrettyCode from "rehype-pretty-code";
import { CopyButton } from "@/components/site/copy-button";
import { useMDXComponents } from "@/mdx-components";

const originalClipboard = Object.getOwnPropertyDescriptor(
  navigator,
  "clipboard",
);
const writeText = mock<(text: string) => Promise<void>>();

beforeEach(() => {
  writeText.mockReset();
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: { writeText },
  });
});

afterEach(() => {
  cleanup();
  jest.useRealTimers();
  if (originalClipboard)
    Object.defineProperty(navigator, "clipboard", originalClipboard);
  else Reflect.deleteProperty(navigator, "clipboard");
});

async function clickCopy(name = "Copy to clipboard") {
  await act(async () => {
    fireEvent.click(screen.getByRole("button", { name }));
  });
}

test("copies an explicit value and resets success after 1600ms", async () => {
  jest.useFakeTimers();
  writeText.mockResolvedValue(undefined);
  render(<CopyButton value={"  bun install\n"} label />);
  await clickCopy();
  expect(writeText).toHaveBeenCalledWith("  bun install");
  expect(screen.getByRole("button", { name: "Copied" }).textContent).toBe(
    "Copied",
  );
  expect(screen.getByRole("status").textContent).toBe("Copied to clipboard.");
  act(() => {
    jest.advanceTimersByTime(1599);
  });
  expect(screen.getByRole("button", { name: "Copied" })).toBeDefined();
  act(() => {
    jest.advanceTimersByTime(1);
  });
  expect(
    screen.getByRole("button", { name: "Copy to clipboard" }).textContent,
  ).toBe("Copy");
  expect(screen.getByRole("status").textContent).toBe("");
});

test("extracts all lines from the nearest highlighted MDX code block", async () => {
  writeText.mockResolvedValue(undefined);
  const source = "```sh\nfirst command\n  second command\nlast command\n```";
  const { default: Content } = await evaluate(source, {
    ...runtime,
    rehypePlugins: [[rehypePrettyCode, { theme: "github-light" }]],
  });
  render(
    <>
      <div className="code-block">
        <pre>unrelated code</pre>
      </div>
      <Content components={useMDXComponents()} />
    </>,
  );
  await clickCopy();
  expect(writeText).toHaveBeenCalledWith(
    "first command\n  second command\nlast command",
  );
});

test("preserves blank lines and indentation in plain code blocks", async () => {
  writeText.mockResolvedValue(undefined);
  render(
    <div className="code-block">
      <pre>{"first line\n\n  indented line\n"}</pre>
      <CopyButton />
    </div>,
  );
  await clickCopy();
  expect(writeText).toHaveBeenCalledWith("first line\n\n  indented line");
});

test("waits for the clipboard write before showing success", async () => {
  let resolve!: () => void;
  writeText.mockReturnValue(
    new Promise<void>((done) => {
      resolve = done;
    }),
  );
  render(<CopyButton value="pending" />);
  fireEvent.click(screen.getByRole("button", { name: "Copy to clipboard" }));
  expect(screen.queryByRole("button", { name: "Copied" })).toBeNull();
  await act(async () => {
    resolve();
  });
  expect(screen.getByRole("button", { name: "Copied" })).toBeDefined();
});

test.each(["missing", "rejected", "throws"])(
  "reports %s clipboard writes accessibly and allows retry",
  async (failure) => {
    if (failure === "missing")
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: undefined,
      });
    else if (failure === "rejected")
      writeText.mockRejectedValue(new Error("Permission denied"));
    else
      writeText.mockImplementation(() => {
        throw new Error("Unavailable");
      });
    render(<CopyButton value="retry me" />);
    await clickCopy();
    expect(
      screen.getByRole("button", { name: "Copy failed. Try again" })
        .textContent,
    ).toContain("Copy failed");
    expect(screen.getByRole("status").textContent).toContain(
      "Select the text to copy manually",
    );
    expect(screen.queryByRole("button", { name: "Copied" })).toBeNull();

    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });
    writeText.mockResolvedValue(undefined);
    await clickCopy("Copy failed. Try again");
    expect(writeText).toHaveBeenLastCalledWith("retry me");
    expect(screen.getByRole("button", { name: "Copied" })).toBeDefined();
    expect(screen.getByRole("status").textContent).toBe("Copied to clipboard.");
  },
);
