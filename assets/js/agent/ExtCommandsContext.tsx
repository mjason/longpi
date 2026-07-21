import { createContext, useContext } from "react";
import type { ExtCommand } from "./channel";

/** Extension-registered slash commands for the current conversation, surfaced
 * to the composer's slash-command menu. */
export const ExtCommandsContext = createContext<ExtCommand[]>([]);

export const useExtCommands = () => useContext(ExtCommandsContext);
