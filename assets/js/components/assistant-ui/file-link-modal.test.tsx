import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { renderWithProviders, screen, waitFor } from "../../test/render";
import { LinkModal, WorkspaceCwdContext } from "./file-link-modal";

// A LinkSafetyModalProps stub with sensible defaults.
function props(overrides: Partial<Parameters<typeof LinkModal>[0]> = {}) {
  return {
    url: "/home/mj/proj/notes.md",
    isOpen: true,
    onClose: () => {},
    onConfirm: () => {},
    ...overrides,
  };
}

function renderModal(
  p: ReturnType<typeof props>,
  cwd: string | null = "/home/mj/proj",
) {
  return renderWithProviders(
    <WorkspaceCwdContext.Provider value={cwd}>
      <LinkModal {...p} />
    </WorkspaceCwdContext.Provider>,
  );
}

describe("LinkModal", () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    vi.stubGlobal("fetch", fetchMock);
    fetchMock.mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const jsonResponse = (body: unknown) => ({ ok: true, json: async () => body });

  describe("given a local text file", () => {
    it("previews its content inline with a download action", async () => {
      fetchMock.mockResolvedValue(
        jsonResponse({
          kind: "text",
          name: "notes.md",
          path: "/home/mj/proj/notes.md",
          size: 128,
          content: "# Hello\nworld",
          truncated: false,
        }),
      );

      renderModal(props());

      expect(await screen.findByText("notes.md")).toBeInTheDocument();
      expect(screen.getByText(/# Hello/)).toBeInTheDocument();
      expect(screen.getByRole("link", { name: /Download/ })).toBeInTheDocument();
      // The preview endpoint was asked for this path, scoped to the workspace.
      const url = fetchMock.mock.calls[0][0] as string;
      expect(url).toContain("/rpc/file?");
      expect(url).toContain("path=");
      expect(url).toContain("cwd=");
    });

    it("notes when the preview was truncated", async () => {
      fetchMock.mockResolvedValue(
        jsonResponse({
          kind: "text",
          name: "big.log",
          path: "/home/mj/proj/big.log",
          size: 999_999,
          content: "x".repeat(10),
          truncated: true,
        }),
      );

      renderModal(props({ url: "/home/mj/proj/big.log" }));
      expect(await screen.findByText(/Preview truncated/)).toBeInTheDocument();
    });
  });

  describe("given a binary file", () => {
    it("says it can't be previewed and offers download", async () => {
      fetchMock.mockResolvedValue(
        jsonResponse({
          kind: "binary",
          name: "blob.bin",
          path: "/home/mj/proj/blob.bin",
          size: 4096,
        }),
      );

      renderModal(props({ url: "/home/mj/proj/blob.bin" }));

      expect(await screen.findByText(/can't be previewed/)).toBeInTheDocument();
      expect(screen.getByRole("link", { name: /Download/ })).toBeInTheDocument();
    });
  });

  describe("given an image file", () => {
    it("renders it from the raw endpoint", async () => {
      fetchMock.mockResolvedValue(
        jsonResponse({
          kind: "image",
          name: "pic.png",
          path: "/home/mj/proj/pic.png",
          size: 2048,
          mime: "image/png",
        }),
      );

      renderModal(props({ url: "/home/mj/proj/pic.png" }));

      const img = (await screen.findByRole("img")) as HTMLImageElement;
      expect(img.getAttribute("src")).toContain("/rpc/file/raw?");
    });
  });

  describe("given a missing file", () => {
    it("reports not found", async () => {
      fetchMock.mockResolvedValue({ ok: false, json: async () => ({}) });

      renderModal(props({ url: "/home/mj/proj/ghost.txt" }));
      expect(await screen.findByText(/File not found/)).toBeInTheDocument();
    });
  });

  describe("given an external URL", () => {
    it("shows the external-link confirm instead of a file preview", async () => {
      renderModal(props({ url: "https://elixir-lang.org/docs" }));

      expect(await screen.findByText(/Open external link/)).toBeInTheDocument();
      expect(screen.getByText("https://elixir-lang.org/docs")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Open link/ })).toBeInTheDocument();
      // A real URL is never sent to the file-preview endpoint.
      expect(fetchMock).not.toHaveBeenCalled();
    });

    it("confirms and closes when Open link is clicked", async () => {
      const onConfirm = vi.fn();
      const onClose = vi.fn();
      renderModal(props({ url: "https://example.com", onConfirm, onClose }));

      (await screen.findByRole("button", { name: /Open link/ })).click();
      await waitFor(() => expect(onConfirm).toHaveBeenCalledOnce());
      expect(onClose).toHaveBeenCalledOnce();
    });
  });
});
