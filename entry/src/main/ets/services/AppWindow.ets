import { window } from '@kit.ArkUI';

// Edge-to-edge background, with explicit insets only for interactive controls.
export class AppWindow {
  static current?: window.Window;
  static topPx: number = 0;
  static bottomPx: number = 0;
  static changed: () => void = () => {};
  private static applied: string = '';

  static async attach(stage: window.WindowStage): Promise<void> {
    AppWindow.current = await stage.getMainWindow();
    await AppWindow.current.setWindowLayoutFullScreen(true);
    AppWindow.measure();
    AppWindow.current.on('avoidAreaChange', () => { AppWindow.measure(); AppWindow.changed(); });
  }

  private static measure(): void {
    if (!AppWindow.current) return;
    AppWindow.topPx = AppWindow.current.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
    AppWindow.bottomPx = AppWindow.current.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
  }

  static apply(bg: string, fg: string, dark: boolean): void {
    if (!AppWindow.current || AppWindow.applied === `${bg}:${fg}:${dark}`) return;
    AppWindow.applied = `${bg}:${fg}:${dark}`;
    try { AppWindow.current.setWindowBackgroundColor(bg); } catch { /* Keep the ArkUI background if the window is not active. */ }
    AppWindow.current.setWindowSystemBarProperties({ statusBarColor: bg, navigationBarColor: bg,
      statusBarContentColor: fg, navigationBarContentColor: fg, isStatusBarLightIcon: dark, isNavigationBarLightIcon: dark }).catch(() => {});
  }

  static detach(): void {
    AppWindow.current?.off('avoidAreaChange'); AppWindow.current = undefined;
    AppWindow.applied = ''; AppWindow.changed = () => {};
  }
}
