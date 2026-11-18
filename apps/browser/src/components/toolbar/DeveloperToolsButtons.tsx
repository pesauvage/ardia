import { View } from "react-native";
import { Button, space } from "../ui";
import type { ToolbarPalette } from "../ui/toolbarColors";
import { useShortcutHint, withShortcut } from "../../state/commands/commandShortcuts";
import { webviews } from "../../state/tabs/webviewHandles";
import { noteDeveloperBarPress } from "../../state/telemetry/developerModeCounts";
import { usePageEngine } from "../../state/engines/hooks";

export const DEVELOPER_BUTTON_ROW = { flexDirection: "row", alignItems: "center", gap: -space.xxs } as const;

export function DeveloperToolsButtons({ tabId, palette, look }: { tabId: string; palette: ToolbarPalette; look: "row" | "field" }) {
  const consoleHint = useShortcutHint("javaScriptConsole");
  const inspectHint = useShortcutHint("inspectElements");
  const engine = usePageEngine(tabId);
  if (engine === "webkit") return null;
  const open = (panel: "console" | "inspect") => () => {
    noteDeveloperBarPress(panel);
    void webviews.get(tabId)?.showDevTools(panel);
  };
  return (
    <View style={DEVELOPER_BUTTON_ROW}>
      <Button variant="icon" toolbar palette={palette} icon="terminal.fill" look={look} onPress={open("console")} tooltip={withShortcut("Toggle Console", consoleHint)} />
      <Button variant="icon" toolbar palette={palette} icon="target" look={look} onPress={open("inspect")} tooltip={withShortcut("Inspect Element", inspectHint)} />
    </View>
  );
}
