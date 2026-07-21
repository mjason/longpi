import { createContext, useContext, useEffect, useState } from "react";
import { buildCSRFHeaders, listEnabledModels } from "../ash_rpc";
import { ModelSelector, type ModelOption } from "../components/assistant-ui/model-selector";
import { modelIcon } from "../components/model-icons";

/** Current conversation's model + live switcher, surfaced to the composer's
 * inline model picker. Null outside a conversation. */
export const ConversationModelContext = createContext<{
  model: string;
  setModel: (spec: string) => void;
} | null>(null);

/**
 * Model switcher docked in the composer action row (ChatGPT/Codex style).
 * Reads the conversation's live model from context; renders nothing when there
 * is no conversation (e.g. the management view has no composer anyway).
 */
export function ComposerModelPicker() {
  const ctx = useContext(ConversationModelContext);
  if (!ctx) return null;
  return <ModelPicker value={ctx.model} onChange={ctx.setModel} align="start" />;
}

/**
 * Header model switcher built on assistant-ui's ModelSelector. Loads the
 * enabled models from the admin-managed list and switches the conversation's
 * model live via the channel (Session.set_model).
 */
export function ModelPicker({
  value,
  onChange,
  align = "end",
}: {
  value: string;
  onChange: (spec: string) => void;
  align?: "start" | "end";
}) {
  const [models, setModels] = useState<ModelOption[]>([]);

  useEffect(() => {
    listEnabledModels({ fields: ["spec", "label"], headers: buildCSRFHeaders() }).then(
      (result) => {
        if (result.success) {
          setModels(
            result.data.map((m) => ({
              id: m.spec,
              name: m.label || m.spec,
              icon: modelIcon(m.spec, m.label),
            })),
          );
        }
      },
    );
  }, []);

  // Keep the current model selectable even if it isn't in the enabled list.
  const options = models.some((m) => m.id === value)
    ? models
    : [{ id: value, name: value, icon: modelIcon(value) }, ...models];

  return (
    <ModelSelector
      models={options}
      value={value}
      onValueChange={onChange}
      align={align}
      searchable
      variant="ghost"
      size="sm"
      // Match the 28px composer controls (attach, approval, context ring, send).
      className="h-7"
    />
  );
}
