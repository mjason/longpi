import { Component, type ErrorInfo, type ReactNode } from "react";
import { Button } from "./ui/button";

type Props = { children: ReactNode };
type State = { error: Error | null };

/**
 * Catches render errors so a single bad message can't white-screen the whole
 * app. Shows the error and a reset button instead.
 */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("Longpi UI crashed:", error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;

    return (
      <div className="grid h-screen place-items-center bg-background p-6 text-foreground">
        <div className="max-w-md text-center">
          <h1 className="mb-2 text-lg font-semibold">Something went wrong</h1>
          <p className="mb-4 text-sm text-muted-foreground">
            The interface hit an error while rendering. Your conversation is saved.
          </p>
          <pre className="mb-4 max-h-40 overflow-auto rounded-md border border-border bg-card p-3 text-left font-mono text-xs text-destructive">
            {this.state.error.message}
          </pre>
          <Button onClick={() => this.setState({ error: null })}>Try again</Button>
        </div>
      </div>
    );
  }
}
