import { useEffect, useState } from "react";
import { buildCSRFHeaders, listEnabledModels } from "../ash_rpc";
import { ModelSelector, type ModelOption } from "../components/assistant-ui/model-selector";

/**
 * Header model switcher built on assistant-ui's ModelSelector. Loads the
 * enabled models from the admin-managed list and switches the conversation's
 * model live via the channel (Session.set_model).
 */
export function ModelPicker({
  value,
  onChange,
}: {
  value: string;
  onChange: (spec: string) => void;
}) {
  const [models, setModels] = useState<ModelOption[]>([]);

  useEffect(() => {
    listEnabledModels({ fields: ["spec", "label"], headers: buildCSRFHeaders() }).then(
      (result) => {
        if (result.success) {
          setModels(result.data.map((m) => ({ id: m.spec, name: m.label || m.spec })));
        }
      },
    );
  }, []);

  // Keep the current model selectable even if it isn't in the enabled list.
  const options = models.some((m) => m.id === value)
    ? models
    : [{ id: value, name: value }, ...models];

  return (
    <ModelSelector
      models={options}
      value={value}
      onValueChange={onChange}
      align="end"
      searchable
      variant="ghost"
      size="sm"
    />
  );
}
