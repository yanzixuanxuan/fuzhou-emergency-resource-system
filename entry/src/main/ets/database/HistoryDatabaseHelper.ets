import relationalStore from '@ohos.data.relationalStore';

/**
 * 历史查询记录数据模型
 */
export interface HistoryRecord {
  id?: number;              // 主键ID，自增
  operation_type: string;   // 操作类型：spatial_query
  event_time: string;       // 查询时间
  center_lon: number;       // 中心经度
  center_lat: number;       // 中心纬度
  radius_km: number;        // 查询半径(km)
  result_count: number;     // 结果数量
  hospital_count: number;   // 医院数量
  police_count: number;     // 派出所数量
  fire_count: number;       // 消防站数量
  summary: string;          // 摘要信息
  payload: string;          // 完整数据(JSON字符串)
}

/**
 * 数据库统计信息
 */
export interface DbStatistics {
  totalRecords: number;        // 总记录数
  totalQueries: number;        // 查询总次数
  avgRadiusKm: number;         // 平均查询半径
  maxRadiusKm: number;         // 最大查询半径
  mostQueriedCenter: string;   // 最常见查询中心
}

/**
 * 历史记录数据库操作类
 * 参考实验六 DatabaseHelper 的设计模式
 * 提供完整的CRUD + 统计 + 分页 + 时间范围查询能力
 */
export class HistoryDatabaseHelper {
  private static instance: HistoryDatabaseHelper | null = null;
  private store: relationalStore.RdbStore | null = null;
  private readonly TABLE_NAME: string = 'map_operation';
  private context: Context | null = null;

  /**
   * 单例模式获取实例
   * @param context 上下文
   * @returns DatabaseHelper实例
   */
  static async getInstance(context: Context): Promise<HistoryDatabaseHelper> {
    if (!HistoryDatabaseHelper.instance) {
      const helper = new HistoryDatabaseHelper();
      helper.context = context;
      await helper.initDatabase();
      HistoryDatabaseHelper.instance = helper;
      console.info('✅ HistoryDatabaseHelper 单例创建成功');
    }
    return HistoryDatabaseHelper.instance;
  }

  /**
   * 私有构造函数，防止外部直接new
   */
  private constructor() {}

  // ==============================================
  // 初始化
  // ==============================================

  /**
   * 初始化数据库
   */
  private async initDatabase(): Promise<void> {
    try {
      const STORE_CONFIG: relationalStore.StoreConfig = {
        name: 'emergency_map.db',
        securityLevel: relationalStore.SecurityLevel.S1
      };

      this.store = await relationalStore.getRdbStore(this.context!, STORE_CONFIG);
      await this.createTable();
      console.info('✅ 历史记录数据库初始化成功');
    } catch (err) {
      console.error('❌ 历史记录数据库初始化失败: ' + JSON.stringify(err));
    }
  }

  /**
   * 创建数据表（含索引）
   */
  private async createTable(): Promise<void> {
    const createSql = `CREATE TABLE IF NOT EXISTS ${this.TABLE_NAME} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      operation_type TEXT NOT NULL,
      event_time TEXT NOT NULL,
      center_lon REAL,
      center_lat REAL,
      radius_km REAL,
      result_count INTEGER DEFAULT 0,
      hospital_count INTEGER DEFAULT 0,
      police_count INTEGER DEFAULT 0,
      fire_count INTEGER DEFAULT 0,
      summary TEXT,
      payload TEXT
    )`;

    // 为时间字段创建索引，加速按时间范围查询
    const indexSql = `CREATE INDEX IF NOT EXISTS idx_event_time
      ON ${this.TABLE_NAME} (event_time)`;

    try {
      await this.store?.executeSql(createSql);
      await this.store?.executeSql(indexSql);
      console.info('✅ 数据表及索引创建成功');
    } catch (err) {
      console.error('❌ 创建数据表失败: ' + JSON.stringify(err));
    }
  }

  // ==============================================
  // 写入操作
  // ==============================================

  /**
   * 插入历史记录
   * @param record 历史记录对象
   * @returns 插入的行ID，失败返回-1
   */
  async insertRecord(record: HistoryRecord): Promise<number> {
    if (!this.store) {
      console.error('❌ 数据库未初始化');
      return -1;
    }

    const valueBucket: relationalStore.ValuesBucket = {
      'operation_type': record.operation_type,
      'event_time': record.event_time,
      'center_lon': record.center_lon,
      'center_lat': record.center_lat,
      'radius_km': record.radius_km,
      'result_count': record.result_count,
      'hospital_count': record.hospital_count,
      'police_count': record.police_count,
      'fire_count': record.fire_count,
      'summary': record.summary,
      'payload': record.payload
    };

    try {
      const rowId = await this.store.insert(this.TABLE_NAME, valueBucket);
      console.info(`✅ 历史记录插入成功，ID: ${rowId}`);
      return rowId;
    } catch (err) {
      console.error('❌ 插入失败: ' + JSON.stringify(err));
      return -1;
    }
  }

  // ==============================================
  // 查询操作
  // ==============================================

  /**
   * 查询所有历史记录（按时间倒序）
   * @returns 历史记录列表
   */
  async queryAllRecords(): Promise<HistoryRecord[]> {
    if (!this.store) {
      console.error('❌ 数据库未初始化');
      return [];
    }

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.orderByDesc('event_time');

    try {
      const resultSet = await this.store.query(predicates);
      const records = this.parseResultSet(resultSet);
      resultSet.close();
      console.info(`✅ 查询成功，共 ${records.length} 条记录`);
      return records;
    } catch (err) {
      console.error('❌ 查询失败: ' + JSON.stringify(err));
      return [];
    }
  }

  /**
   * 根据ID查询单条记录
   * @param id 记录ID
   * @returns 记录对象，未找到返回null
   */
  async queryRecordById(id: number): Promise<HistoryRecord | null> {
    if (!this.store) return null;

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.equalTo('id', id);

    try {
      const resultSet = await this.store.query(predicates);
      const records = this.parseResultSet(resultSet);
      resultSet.close();
      return records.length > 0 ? records[0] : null;
    } catch (err) {
      console.error(`❌ 查询ID=${id}失败: ` + JSON.stringify(err));
      return null;
    }
  }

  /**
   * 按时间范围查询记录
   * @param startTime 起始时间（含）
   * @param endTime 结束时间（含）
   * @returns 历史记录列表（按时间倒序）
   */
  async queryRecordsByTimeRange(startTime: string, endTime: string): Promise<HistoryRecord[]> {
    if (!this.store) return [];

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.greaterThanOrEqualTo('event_time', startTime);
    predicates.and();
    predicates.lessThanOrEqualTo('event_time', endTime);
    predicates.orderByDesc('event_time');

    try {
      const resultSet = await this.store.query(predicates);
      const records = this.parseResultSet(resultSet);
      resultSet.close();
      console.info(`✅ 时间范围查询成功，共 ${records.length} 条`);
      return records;
    } catch (err) {
      console.error('❌ 时间范围查询失败: ' + JSON.stringify(err));
      return [];
    }
  }

  /**
   * 分页查询
   * @param page 页码（从0开始）
   * @param pageSize 每页条数
   * @returns 历史记录列表（按时间倒序）
   */
  async queryRecordsByPage(page: number, pageSize: number): Promise<HistoryRecord[]> {
    if (!this.store) return [];

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.orderByDesc('event_time');
    predicates.limitAs(pageSize);

    try {
      const resultSet = await this.store.query(predicates);
      const records = this.parseResultSet(resultSet);
      resultSet.close();
      return records;
    } catch (err) {
      console.error('❌ 分页查询失败: ' + JSON.stringify(err));
      return [];
    }
  }

  // ==============================================
  // 删除操作
  // ==============================================

  /**
   * 根据ID删除单条记录
   * @param id 记录ID
   * @returns 是否删除成功
   */
  async deleteRecordById(id: number): Promise<boolean> {
    if (!this.store) return false;

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.equalTo('id', id);

    try {
      const rows = await this.store.delete(predicates);
      const success = rows > 0;
      if (success) {
        console.info(`✅ 删除记录成功，ID: ${id}`);
      } else {
        console.warn(`⚠️ 未找到ID为 ${id} 的记录`);
      }
      return success;
    } catch (err) {
      console.error('❌ 删除失败: ' + JSON.stringify(err));
      return false;
    }
  }

  /**
   * 清空所有记录
   * @returns 是否清空成功
   */
  async clearAllRecords(): Promise<boolean> {
    if (!this.store) return false;

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);

    try {
      const rows = await this.store.delete(predicates);
      console.info(`✅ 清空成功，共删除 ${rows} 条记录`);
      return true;
    } catch (err) {
      console.error('❌ 清空失败: ' + JSON.stringify(err));
      return false;
    }
  }

  /**
   * 删除指定时间之前的记录（归档/清理）
   * @param beforeTime 时间边界，删除该时间之前的记录
   * @returns 删除的记录数
   */
  async deleteRecordsBefore(beforeTime: string): Promise<number> {
    if (!this.store) return 0;

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.lessThan('event_time', beforeTime);

    try {
      const rows = await this.store.delete(predicates);
      console.info(`✅ 清理完成，删除 ${rows} 条历史记录`);
      return rows;
    } catch (err) {
      console.error('❌ 清理失败: ' + JSON.stringify(err));
      return 0;
    }
  }

  // ==============================================
  // 统计查询
  // ==============================================

  /**
   * 获取记录总数
   * @returns 记录数量
   */
  async getRecordCount(): Promise<number> {
    if (!this.store) return 0;

    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);

    try {
      const resultSet = await this.store.query(predicates);
      const count = resultSet.rowCount;
      resultSet.close();
      return count;
    } catch (err) {
      console.error('❌ 获取记录数失败: ' + JSON.stringify(err));
      return 0;
    }
  }

  /**
   * 获取数据库统计信息
   * @returns 统计对象
   */
  async getStatistics(): Promise<DbStatistics> {
    const stats: DbStatistics = {
      totalRecords: 0,
      totalQueries: 0,
      avgRadiusKm: 0,
      maxRadiusKm: 0,
      mostQueriedCenter: ''
    };

    if (!this.store) return stats;

    try {
      // 总记录数
      stats.totalRecords = await this.getRecordCount();

      // 聚合统计：总查询次数、平均/最大半径
      const allRecords = await this.queryAllRecords();
      stats.totalQueries = allRecords.length;

      if (allRecords.length > 0) {
        let totalRadius = 0;
        let maxRadius = 0;
        const centerMap: Record<string, number> = {};

        for (const r of allRecords) {
          totalRadius += r.radius_km || 0;
          if ((r.radius_km || 0) > maxRadius) maxRadius = r.radius_km || 0;

          // 统计查询中心频率
          const key = `${r.center_lon?.toFixed(2)},${r.center_lat?.toFixed(2)}`;
          centerMap[key] = (centerMap[key] || 0) + 1;
        }

        stats.avgRadiusKm = Number((totalRadius / allRecords.length).toFixed(2));
        stats.maxRadiusKm = maxRadius;

        // 最常见的查询中心
        let maxCount = 0;
        const entries = Object.keys(centerMap);
        for (let i = 0; i < entries.length; i++) {
          const key = entries[i];
          const count = centerMap[key] as number;
          if (count > maxCount) {
            maxCount = count;
            stats.mostQueriedCenter = key;
          }
        }
      }

      return stats;
    } catch (err) {
      console.error('❌ 获取统计失败: ' + JSON.stringify(err));
      return stats;
    }
  }

  // ==============================================
  // 工具方法
  // ==============================================

  /**
   * 将 ResultSet 解析为 HistoryRecord 列表
   * @param resultSet 查询结果集
   * @returns 记录列表
   */
  private parseResultSet(resultSet: relationalStore.ResultSet): HistoryRecord[] {
    const records: HistoryRecord[] = [];
    try {
      while (resultSet.goToNextRow()) {
        records.push({
          id: resultSet.getLong(resultSet.getColumnIndex('id')),
          operation_type: resultSet.getString(resultSet.getColumnIndex('operation_type')),
          event_time: resultSet.getString(resultSet.getColumnIndex('event_time')),
          center_lon: resultSet.getDouble(resultSet.getColumnIndex('center_lon')),
          center_lat: resultSet.getDouble(resultSet.getColumnIndex('center_lat')),
          radius_km: resultSet.getDouble(resultSet.getColumnIndex('radius_km')),
          result_count: resultSet.getLong(resultSet.getColumnIndex('result_count')),
          hospital_count: resultSet.getLong(resultSet.getColumnIndex('hospital_count')),
          police_count: resultSet.getLong(resultSet.getColumnIndex('police_count')),
          fire_count: resultSet.getLong(resultSet.getColumnIndex('fire_count')),
          summary: resultSet.getString(resultSet.getColumnIndex('summary')),
          payload: resultSet.getString(resultSet.getColumnIndex('payload'))
        });
      }
    } catch (err) {
      console.error('❌ 解析ResultSet失败: ' + JSON.stringify(err));
    }
    return records;
  }
}
