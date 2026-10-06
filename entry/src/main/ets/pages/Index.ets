import web_webview from '@ohos.web.webview';
import { HistoryDatabaseHelper, HistoryRecord } from '../database/HistoryDatabaseHelper';
import prompt from '@ohos.prompt';
import common from '@ohos.app.ability.common';

// 前端传递的查询数据类型
interface QueryData {
  center_lon: number;
  center_lat: number;
  radius_km: number;
  result_count: number;
  hospital_count: number;
  police_count: number;
  fire_count: number;
  summary: string;
}

/**
 * NativeBridge —— 由 Web 页面通过 javaScriptProxy 调用的 ArkTS 对象
 * 接收来自前端地图的操作记录并写入数据库
 *
 * 设计说明：
 * - 在字段声明时直接实例化，确保 Web 组件 .javaScriptProxy() 时 bridge 对象一定存在
 * - dbHelper 使用 setter 延迟注入，解决异步初始化时序问题
 */
class NativeBridge {
  private dbHelper: HistoryDatabaseHelper | null = null;
  private pendingQueue: HistoryRecord[] = [];

  /** 延迟注入 dbHelper（异步初始化完成后调用） */
  setDbHelper(helper: HistoryDatabaseHelper): void {
    this.dbHelper = helper;
    console.info('✅ NativeBridge dbHelper 注入完成');
    // 处理积压的待保存记录
    this.flushPendingQueue();
  }

  /** 处理数据库就绪前的积压记录 */
  private async flushPendingQueue(): Promise<void> {
    if (this.pendingQueue.length === 0) return;
    console.info(`📦 正在处理 ${this.pendingQueue.length} 条积压记录`);
    for (const record of this.pendingQueue) {
      try {
        const rowId = await this.dbHelper!.insertRecord(record);
        console.info(`✅ 积压记录保存成功, rowId=${rowId}`);
      } catch (e) {
        console.error(`❌ 积压记录保存失败: ${e}`);
      }
    }
    this.pendingQueue = [];
  }

  /** 地图加载完成回调 */
  onMapLoaded(): void {
    console.info('✅ Web 地图加载完成');
  }

  /** 地图点击回调 */
  onMapClick(lon: number, lat: number): void {
    console.info(`📍 地图点击: ${lon}, ${lat}`);
  }

  /** 通用日志 */
  log(message: string): void {
    console.info(`📋 Web日志: ${message}`);
  }

  /** 保存操作记录到数据库 */
  saveOperation(data: string): void {
    try {
      if (!data) {
        console.warn('⚠️ saveOperation 收到空数据');
        return;
      }

      const obj = JSON.parse(data) as Partial<QueryData>;

      const record: HistoryRecord = {
        operation_type: "spatial_query",
        event_time: new Date().toISOString(),
        center_lon: obj.center_lon ?? 0,
        center_lat: obj.center_lat ?? 0,
        radius_km: obj.radius_km ?? 0,
        result_count: obj.result_count ?? 0,
        hospital_count: obj.hospital_count ?? 0,
        police_count: obj.police_count ?? 0,
        fire_count: obj.fire_count ?? 0,
        summary: obj.summary ?? "",
        payload: data
      };

      // 数据库尚未初始化时先放入队列，初始化完成后自动写入
      if (!this.dbHelper) {
        console.info('⏳ 数据库尚未初始化，放入待处理队列:', record.summary);
        this.pendingQueue.push(record);
        return;
      }

      const rowId = this.dbHelper.insertRecord(record);
      console.info(`✅ 数据库保存成功, rowId=${rowId}`);
    } catch (e) {
      console.error(`❌ saveOperation 解析失败: ${e}`);
    }
  }
}

@Entry
@Component
struct Index {
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private db: HistoryDatabaseHelper | null = null;
  // 在字段声明时直接创建 bridge，确保 Web 组件构建时一定存在
  private bridge: NativeBridge = new NativeBridge();

  @State showHistory: boolean = false;
  @State historyList: HistoryRecord[] = [];
  @State recordCount: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.db = await HistoryDatabaseHelper.getInstance(ctx);
      // 异步初始化完成后注入 dbHelper
      this.bridge.setDbHelper(this.db);
      console.info('✅ 数据库初始化完成');
    } catch (e) {
      console.error(`❌ 初始化失败: ${e}`);
    }
  }

  /** 刷新历史列表 */
  async refreshHistoryList(): Promise<void> {
    if (!this.db) return;
    this.historyList = await this.db.queryAllRecords();
    this.recordCount = await this.db.getRecordCount();
  }

  /** 打开历史面板 */
  async openHistory(): Promise<void> {
    await this.refreshHistoryList();
    this.showHistory = true;
  }

  /** 关闭历史面板 */
  closeHistory(): void {
    this.showHistory = false;
  }

  /** 恢复选中的历史记录 */
  restoreRecord(item: HistoryRecord): void {
    try {
      // payload 已经是 JSON.stringify(data) 生成的合法 JSON 字符串
      // 直接插入到 JS 调用中作为对象字面量：
      // restoreQuery({"center_lon":119.30,"center_lat":26.08,...})
      // 注意：不能再次 JSON.stringify，否则会产生双层转义导致 JS 收到字符串而非对象
      this.webController.runJavaScript(`restoreQuery(${item.payload})`);
      this.closeHistory();
      prompt.showToast({ message: "正在恢复查询...", duration: 1500 });
    } catch (e) {
      console.error(`❌ 恢复记录失败: ${e}`);
      prompt.showToast({ message: "恢复失败" });
    }
  }

  /** 删除单条记录 */
  async deleteRecord(id: number): Promise<void> {
    if (!this.db) return;
    const success = await this.db.deleteRecordById(id);
    if (success) {
      prompt.showToast({ message: "已删除" });
      await this.refreshHistoryList();
    } else {
      prompt.showToast({ message: "删除失败" });
    }
  }

  /** 清空所有记录 */
  async clearAllRecords(): Promise<void> {
    if (!this.db) return;
    try {
      const success = await this.db.clearAllRecords();
      if (success) {
        prompt.showToast({ message: "已清空所有记录" });
        await this.refreshHistoryList();
      }
    } catch (e) {
      console.error(`❌ 清空失败: ${e}`);
    }
  }

  build() {
    Stack() {
      // ==============================================
      // 主界面：WebView + 顶部按钮栏
      // ==============================================
      Column() {
        // 顶部操作栏
        Row() {
          Button("📍 福州中心")
            .onClick(() => {
              this.webController.runJavaScript('goToLocation(119.3000, 26.0800, 13)');
            })

          Button("🗑️ 清除")
            .onClick(() => {
              this.webController.runJavaScript('clearGraphics()');
            })

          Button("📋 历史记录")
            .onClick(async () => {
              await this.openHistory();
            })
        }
        .padding(8)
        .justifyContent(FlexAlign.SpaceAround)

        // WebView 地图
        // 使用 .javaScriptProxy() 在 Web 组件构建时直接注册桥接对象
        // 这是实验指导文档推荐的方式，比动态 registerJavaScriptProxy 更稳定
        Web({
          src: $rawfile("map.html"),
          controller: this.webController
        })
          .width("100%")
          .height("100%")
          .javaScriptAccess(true)
          .domStorageAccess(true)
          // 静态注册 javaScriptProxy —— 页面加载后自动生效，无需 refresh()
          .javaScriptProxy({
            object: this.bridge as NativeBridge,
            name: "NativeBridge",
            methodList: [
              "onMapLoaded",
              "onMapClick",
              "log",
              "saveOperation"
            ],
            controller: this.webController
          })
      }

      // ==============================================
      // 历史记录面板（覆盖层）
      // ==============================================
      if (this.showHistory) {
        Column() {
          // 面板标题栏
          Row() {
            Text(`📋 历史记录 (${this.recordCount})`)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)

            Blank()

            if (this.recordCount > 0) {
              Button("清空全部")
                .fontColor(Color.Red)
                .onClick(() => {
                  this.clearAllRecords();
                })
            }

            Button("关闭")
              .onClick(() => {
                this.closeHistory();
              })
          }
          .padding(12)
          .width("100%")

          // 列表内容
          if (this.historyList.length === 0) {
            Column() {
              Text("暂无历史记录")
                .fontColor(Color.Gray)
                .margin({ top: 40 })
            }
            .width("100%")
            .height("100%")
            .justifyContent(FlexAlign.Start)
          } else {
            List() {
              ForEach(this.historyList, (item: HistoryRecord) => {
                ListItem() {
                  // 每条记录的卡片
                  Column() {
                    // 第一行：时间 + 操作类型
                    Row() {
                      Text(`[${item.operation_type}]`)
                        .fontSize(13)
                        .fontColor(Color.Orange)
                      Blank()
                      Text(item.event_time)
                        .fontSize(12)
                        .fontColor(Color.Gray)
                    }
                    .width("100%")

                    // 第二行：概要
                    Text(item.summary)
                      .fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .margin({ top: 4, bottom: 4 })

                    // 第三行：详细参数
                    Row() {
                      Text(`中心: ${item.center_lon?.toFixed(4)}, ${item.center_lat?.toFixed(4)}`)
                        .fontSize(12)
                        .fontColor(Color.Gray)
                      Blank()
                      Text(`半径: ${item.radius_km}km`)
                        .fontSize(12)
                        .fontColor(Color.Gray)
                    }
                    .width("100%")

                    // 第四行：各类资源统计
                    if (item.hospital_count !== 0 || item.police_count !== 0 || item.fire_count !== 0) {
                      Row() {
                        Text(`🏥${item.hospital_count}`)
                          .fontSize(12)
                          .fontColor(Color.Red)
                        Text(`  👮${item.police_count}`)
                          .fontSize(12)
                          .fontColor(Color.Blue)
                        Text(`  🔥${item.fire_count}`)
                          .fontSize(12)
                          .fontColor(Color.Orange)
                      }
                      .width("100%")
                      .margin({ top: 2 })
                    }

                    // 第五行：操作按钮
                    Row() {
                      Blank()
                      Button("恢复")
                        .fontSize(13)
                        .onClick(() => {
                          this.restoreRecord(item);
                        })
                      Button("删除")
                        .fontSize(13)
                        .fontColor(Color.Red)
                        .onClick(() => {
                          this.deleteRecord(item.id!);
                        })
                    }
                    .width("100%")
                    .margin({ top: 6 })
                  }
                  .padding(12)
                  .borderRadius(8)
                  .border({ width: 1, color: "#e0e0e0" })
                  .backgroundColor("#f9f9f9")
                }
              })
            }
            .width("100%")
            .layoutWeight(1)
            .padding({ left: 12, right: 12 })
          }
        }
        .width("100%")
        .height("100%")
        .backgroundColor(Color.White)
        .alignItems(HorizontalAlign.Start)
      }
    }
  }
}
