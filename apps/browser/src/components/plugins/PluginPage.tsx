import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { Box, Button, PluginPageView, Text } from "../ui";
import { useTheme } from "../ui/theme";
import { useTab } from "../../state/browser/hooks";
import { usePluginActive, usePluginFolderId, usePluginNetwork, usePluginPageToken, usePluginPageContext, usePluginPageSpec, usePluginPageUrl, usePluginProcess } from "../../state/plugins/hooks";
import { openPageLink, pluginPagePath } from "../../state/plugins/actions";
import { openSettings } from "../../state/settings/settingsWindows";

function Notice({ title, detail, name }: { title: string; detail: string; name: string }) {
  return (
    <Box pad="xl" gap="m" style={CENTER}>
      <Text size="title" weight="semibold">
        {title}
      </Text>
      <Text tone="textSecondary">{detail}</Text>
      <Button title="Open Plugin Settings" onPress={() => openSettings("plugins", null, name)} />
    </Box>
  );
}

export function PluginPage({ tabId, name }: { tabId: string; name: string }) {
  const theme = useTheme();
  const windowId = useTab(tabId, (t) => t?.windowId ?? "");
  const path = useTab(tabId, (t) => pluginPagePath(t?.url ?? ""));
  const spec = usePluginPageSpec(name);
  const active = usePluginActive(name);
  const context = usePluginPageContext(tabId);
  const url = usePluginPageUrl(name, context, path);
  const process = usePluginProcess(name);
  const network = usePluginNetwork(name);
  const folderId = usePluginFolderId(name);
  const pageToken = usePluginPageToken(name);
  const [refused, setRefused] = useState<string | null>(null);
  if (!spec || !active) return <Notice name={name} title={`${spec?.title ?? name} is off`} detail="Turn the plugin on in Settings › Plugins to use its page." />;
  if (!url) {
    const failed = process?.state === "crashed" || process?.state === "failed";
    return <Notice name={name} title={failed ? `${spec.title} stopped` : `${spec.title} is starting…`} detail={failed ? "Its program isn't running. Restart it from Settings › Plugins." : "Its program is getting the page ready."} />;
  }
  if (refused === url)
    return <Notice name={name} title={`${spec.title} didn't load`} detail="Its page server didn't prove it belongs to the plugin, so Ardia didn't open it. Restart the plugin from Settings › Plugins." />;
  return (
    <View style={[StyleSheet.absoluteFill, { backgroundColor: theme.card }]}>
      <PluginPageView style={StyleSheet.absoluteFill} plugin={name} url={url} network={network} folderId={folderId} pageToken={pageToken} onRefused={(e) => setRefused(e.nativeEvent.url)} onOpenUrl={(e) => openPageLink(windowId, e.nativeEvent.url)} />
    </View>
  );
}

const CENTER = { flex: 1, alignItems: "center", justifyContent: "center" } as const;
