import { beforeEach, expect, mock, test } from "bun:test";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { SearchEntry } from "@/lib/docs";

const push = mock<(href: string) => void>();
mock.module("next/navigation", () => ({ useRouter: () => ({ push }) }));
const { Search } = await import("@/components/site/search");

const index: SearchEntry[] = [
  {
    slug: "models",
    title: "Models and downloads",
    description: "Download verified weights",
    section: "Start here",
    headings: [{ id: "storage", text: "Storage location", depth: 2 }],
  },
  {
    slug: "server",
    title: "Running the server",
    description: "Keep models resident over a socket",
    section: "Integrate",
    headings: [{ id: "voice_profiles", text: "Voice profiles", depth: 2 }],
  },
];

beforeEach(() => {
  push.mockReset();
});

async function openSearch() {
  render(<Search index={index} />);
  fireEvent.click(screen.getByRole("button", { name: /Search/ }));
  return await screen.findByRole("combobox");
}

test("empty search shows pages and headings", async () => {
  await openSearch();
  expect((await screen.findAllByRole("option")).length).toBe(4);
  expect(screen.queryByText("No results.")).toBeNull();
});

test.each([
  [
    "MoDeLs",
    ["Models and downloads", "Storage location", "Running the server"],
  ],
  ["socket resident", ["Running the server"]],
  ["  SERVER   voice  ", ["Voice profiles"]],
])(
  "filters case-insensitively and requires every query word: %s",
  async (query, expected) => {
    const input = await openSearch();
    fireEvent.change(input, { target: { value: query } });
    await waitFor(() => {
      const options = screen.getAllByRole("option");
      expect(options).toHaveLength(expected.length);
      for (const text of expected)
        expect(
          options.some((option) => option.textContent?.includes(text)),
        ).toBe(true);
    });
  },
);

test("shows no matches and restores results when cleared", async () => {
  const input = await openSearch();
  fireEvent.change(input, { target: { value: "not-a-doc" } });
  expect(await screen.findByText("No results.")).toBeDefined();
  expect(screen.queryAllByRole("option")).toHaveLength(0);
  fireEvent.change(input, { target: { value: "" } });
  await waitFor(() => {
    expect(screen.getAllByRole("option")).toHaveLength(4);
  });
});

test("whitespace-only queries show all results and scattered letters do not match", async () => {
  const input = await openSearch();
  fireEvent.change(input, { target: { value: "   " } });
  await waitFor(() => {
    expect(screen.getAllByRole("option")).toHaveLength(4);
  });
  fireEvent.change(input, { target: { value: "mdlnd" } });
  expect(await screen.findByText("No results.")).toBeDefined();
  expect(screen.queryAllByRole("option")).toHaveLength(0);
});

test.each(["metaKey", "ctrlKey"])(
  "%s+K toggles the dialog and prevents the browser shortcut",
  async (modifier) => {
    render(<Search index={index} />);
    const event = new KeyboardEvent("keydown", {
      key: "k",
      [modifier]: true,
      bubbles: true,
      cancelable: true,
    });
    fireEvent(window, event);
    expect(event.defaultPrevented).toBe(true);
    expect(await screen.findByRole("dialog")).toBeDefined();
    fireEvent.keyDown(window, { key: "k", [modifier]: true });
    await waitFor(() => {
      expect(screen.queryByRole("dialog")).toBeNull();
    });
  },
);

test.each([
  ["Models and downloads", "/docs/models"],
  ["Voice profiles Running the server", "/docs/server#voice_profiles"],
])("selecting %s navigates and dismisses the dialog", async (name, href) => {
  await openSearch();
  fireEvent.click(await screen.findByRole("option", { name }));
  expect(push).toHaveBeenCalledWith(href);
  await waitFor(() => {
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});

test("keyboard selection preserves the heading hash", async () => {
  const input = await openSearch();
  fireEvent.change(input, { target: { value: "voice profiles" } });
  await waitFor(() => {
    expect(screen.getAllByRole("option")).toHaveLength(1);
  });
  await waitFor(() => {
    expect(screen.getByRole("option").getAttribute("aria-selected")).toBe(
      "true",
    );
  });
  fireEvent.keyDown(input, { key: "Enter" });
  expect(push).toHaveBeenCalledWith("/docs/server#voice_profiles");
  await waitFor(() => {
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});

test("Escape dismisses without navigating", async () => {
  const input = await openSearch();
  fireEvent.keyDown(input, { key: "Escape" });
  await waitFor(() => {
    expect(screen.queryByRole("dialog")).toBeNull();
  });
  expect(push).not.toHaveBeenCalled();
});

test("clicking outside dismisses without navigating", async () => {
  await openSearch();
  const overlay = document.querySelector('[data-slot="dialog-overlay"]')!;
  fireEvent.mouseDown(overlay);
  fireEvent.mouseUp(overlay);
  fireEvent.click(overlay);
  await waitFor(() => {
    expect(screen.queryByRole("dialog")).toBeNull();
  });
  expect(push).not.toHaveBeenCalled();
});
