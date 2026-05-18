import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import App from "./App.jsx";

describe("App", () => {
  it("renders the auth screen when no token is stored", () => {
    localStorage.clear();
    render(<App />);
    expect(screen.getByText(/TaskBoard/i)).toBeTruthy();
  });
});
