-- 1.新建数据库
CREATE DATABASE ecommerce_rfm
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
USE ecommerce_rfm;
-- 导入后验证：
SELECT * FROM user_personalized_features LIMIT 10;
SELECT COUNT(*) FROM user_personalized_features;

-- 2.数据清洗
-- 去除User_ID前的#号（SUBSTRING从第2个字符开始取）
UPDATE user_personalized_features
SET User_ID = SUBSTRING(User_ID, 2);
-- 验证
SELECT User_ID FROM user_personalized_features LIMIT 3;
-- ②将Average_Order_Value改为精确小数类型
-- DECIMAL(10,2)：总位数10位，小数2位
ALTER TABLE user_personalized_features
MODIFY Average_Order_Value DECIMAL(10,2);
-- 验证字段类型
DESCRIBE user_personalized_features;

-- 3.缺失值检测
SELECT User_ID, Age, Gender, Location, Income,
       Total_Spending, Purchase_Frequency, Last_Login_Days_Ago
FROM user_personalized_features
WHERE User_ID IS NULL
   OR Age IS NULL
   OR Gender IS NULL
   OR Total_Spending IS NULL
   OR Purchase_Frequency IS NULL
   OR Last_Login_Days_Ago IS NULL;
-- 重复User_ID检测
SELECT User_ID, COUNT(*) AS cnt
FROM user_personalized_features
GROUP BY User_ID
HAVING COUNT(*) > 1;
-- 确认数值范围合理
SELECT
  MIN(Age) AS min_age,  MAX(Age) AS max_age,
  MIN(Total_Spending) AS min_gmv, MAX(Total_Spending) AS max_gmv,
  MIN(Last_Login_Days_Ago) AS min_gap, MAX(Last_Login_Days_Ago) AS max_gap
FROM user_personalized_features;
-- 检查是否有异常值


-- 4.RFM评分与分层
WITH macro_seg AS (
-- 宏观细分
    SELECT
        CASE
            WHEN r.customer_segment IN ('重要价值客户','重要唤回客户')   THEN '核心客户'
            WHEN r.customer_segment IN ('重要深耕客户','重要挽留客户') THEN '重要客户'
            WHEN r.customer_segment  = '潜力客户'                        THEN '潜力客户'
            WHEN r.customer_segment IN ('一般维持客户','新客户')         THEN '一般客户'
            ELSE '流失客户'
        END AS macro_segment,
        u.Total_Spending
    FROM rfm_customer_segment r
    JOIN user_personalized_features u ON u.User_ID = r.User_ID
)
SELECT
    macro_segment,
--     用户数
    COUNT(*)    AS user_count,
--     人均消费                                           
    ROUND(AVG(Total_Spending), 2)                        AS arpu,
--     总消费
    ROUND(SUM(Total_Spending), 2)                        AS total_gmv,
--     各组总消费占比
    ROUND(SUM(Total_Spending) * 100.0
          / SUM(SUM(Total_Spending)) OVER(), 1)          AS gmv_pct
FROM macro_seg
GROUP BY macro_segment
-- 突出贡献最大的群体
ORDER BY total_gmv DESC;
-- 验证：8个分层应全部存在
SELECT customer_segment, COUNT(*) AS cnt
FROM rfm_customer_segment
GROUP BY customer_segment
ORDER BY cnt DESC;


-- 5. GMV贡献度分析
WITH macro_seg AS (
    SELECT
        CASE
            WHEN r.customer_segment IN ('重要价值客户','重要唤回客户')   THEN '核心客户'
            WHEN r.customer_segment IN ('重要深耕客户','重要挽留客户') THEN '重要客户'
            WHEN r.customer_segment  = '潜力客户'                        THEN '潜力客户'
            WHEN r.customer_segment IN ('一般维持客户','新客户')         THEN '一般客户'
            ELSE '流失客户'
        END AS macro_segment,
        u.Total_Spending
    FROM rfm_customer_segment r
    JOIN user_personalized_features u ON u.User_ID = r.User_ID
)
SELECT
    macro_segment,
    COUNT(*)                                              AS user_count,
    ROUND(AVG(Total_Spending), 2)                        AS arpu,
    ROUND(SUM(Total_Spending), 2)                        AS total_gmv,
    ROUND(SUM(Total_Spending) * 100.0
          / SUM(SUM(Total_Spending)) OVER(), 1)          AS gmv_pct
FROM macro_seg
GROUP BY macro_segment
ORDER BY total_gmv DESC;


-- 6.用户画像建表
CREATE TABLE user_profile_rfm (
    customer_segment   VARCHAR(20) PRIMARY KEY,  -- 客户细分类型（主键）
    user_cnt           INT,                       -- 该群体用户总数
    avg_age            DECIMAL(4,1),              -- 平均年龄（保留1位小数）
    avg_income         INT,                        -- 平均收入（取整）
    dominant_gender    VARCHAR(10),                -- 占主导的性别
    dominant_location  VARCHAR(20),                -- 占主导的地域
    avg_login_gap      DECIMAL(5,1),               -- 平均最近登录间隔天数
    avg_total_spending DECIMAL(10,2),              -- 平均总消费金额
    avg_time_min       DECIMAL(6,1),               -- 平均站内停留时长（分钟）
    sub_rate           DECIMAL(4,2),                -- 订阅比率（0~1之间，百分比）
    top_interest       VARCHAR(50),                 -- 最热门兴趣标签
    top_category       VARCHAR(50)                  -- 最偏好的产品类别
);

-- 向表中插入数据，基于RFM细分结果与用户特征计算各群体的画像指标
INSERT INTO user_profile_rfm
WITH base AS (
    -- 基础聚合：按客户细分类型以及性别、地域、兴趣、偏好类别分组，计算各组合的计数和均值
    SELECT
        r.customer_segment,                           -- RFM细分类型
        u.gender,                                      -- 性别
        u.location,                                    -- 地域
        u.interests,                                   -- 兴趣标签
        u.product_category_preference,                 -- 偏好产品类别
        COUNT(*)                                               AS cnt,           -- 当前组合下的用户数
        AVG(u.age)                                             AS avg_age,       -- 组合内平均年龄
        AVG(u.income)                                          AS avg_income,    -- 组合内平均收入
        AVG(u.last_login_days_ago)                             AS avg_login_gap, -- 组合内平均登录间隔
        AVG(u.total_spending)                                  AS avg_total_spending, -- 组合内平均总消费
        AVG(u.time_spent_on_site_minutes)                      AS avg_time_min,  -- 组合内平均站内时长
        AVG(CASE WHEN u.newsletter_subscription = 'True'
            THEN 1 ELSE 0 END)                              AS sub_rate       -- 组合内平均订阅率
    FROM user_personalized_features u
    JOIN rfm_customer_segment r ON u.User_ID = r.User_ID   -- 关联RFM细分结果
    GROUP BY r.customer_segment, u.gender, u.location,
             u.interests, u.product_category_preference      -- 按五维度分组
),
ranked AS (
    -- 为每个客户细分类型内的组合按用户数降序编号，以便提取众数
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY customer_segment     -- 在每个细分类型内
                           ORDER BY cnt DESC) AS rn          -- 按组合用户数降序编号
    FROM base
)
-- 从ranked中提取每个细分群体的汇总指标，使用加权平均计算整体均值
SELECT DISTINCT
    customer_segment,                                       -- 细分类型
    -- 总用户数 = 各组合用户数之和
    SUM(cnt)           OVER (PARTITION BY customer_segment)                   AS user_cnt,
    -- 加权平均年龄 = (组合用户数 * 组合平均年龄)之和 / 总用户数
    ROUND(SUM(cnt * avg_age) OVER (PARTITION BY customer_segment) / 
          SUM(cnt) OVER (PARTITION BY customer_segment), 1)                AS avg_age,
    -- 加权平均收入
    ROUND(SUM(cnt * avg_income) OVER (PARTITION BY customer_segment) / 
          SUM(cnt) OVER (PARTITION BY customer_segment), 0)                AS avg_income,
    -- 出现次数最多的性别（取rn=1的组合对应的性别）
    FIRST_VALUE(gender) OVER (PARTITION BY customer_segment ORDER BY rn)    AS dominant_gender,
    -- 出现次数最多的地域
    FIRST_VALUE(location) OVER (PARTITION BY customer_segment ORDER BY rn)  AS dominant_location,
    -- 加权平均登录间隔
    ROUND(SUM(cnt * avg_login_gap) OVER (PARTITION BY customer_segment) / 
          SUM(cnt) OVER (PARTITION BY customer_segment), 1)               AS avg_login_gap,
    -- 加权平均总消费
    ROUND(SUM(cnt * avg_total_spending) OVER (PARTITION BY customer_segment) / 
          SUM(cnt) OVER (PARTITION BY customer_segment), 2)              AS avg_total_spending,
    -- 加权平均站内时长
    ROUND(SUM(cnt * avg_time_min) OVER (PARTITION BY customer_segment) / 
          SUM(cnt) OVER (PARTITION BY customer_segment), 1)             AS avg_time_min,
    -- 加权平均订阅率
    ROUND(SUM(cnt * sub_rate) OVER (PARTITION BY customer_segment) / 
          SUM(cnt) OVER (PARTITION BY customer_segment), 2)            AS sub_rate,
    -- 最热兴趣（取用户数最多的组合的兴趣）
    FIRST_VALUE(interests) OVER (PARTITION BY customer_segment ORDER BY rn) AS top_interest,
    -- 最热偏好品类
    FIRST_VALUE(product_category_preference) OVER (PARTITION BY customer_segment ORDER BY rn) AS top_category
FROM ranked;



-- 7.商品消费额 + 渗透率分析 
-- rfm_product.csv
WITH segment_map AS (
    SELECT
        CASE
            WHEN r.customer_segment IN ('重要价值客户','重要唤回客户')   THEN '核心客户'
            WHEN r.customer_segment IN ('重要深耕客户','重要挽留客户') THEN '重要客户'
            WHEN r.customer_segment  = '潜力客户'                        THEN '潜力客户'
            WHEN r.customer_segment IN ('一般维持客户','新客户')         THEN '一般客户'
            ELSE '流失客户'
        END                                     AS macro_segment,
        u.User_ID,
        u.product_category_preference,
        u.Average_Order_Value,
        u.Total_Spending
    FROM rfm_customer_segment r
    JOIN user_personalized_features u ON u.User_ID = r.User_ID
),
seg_size AS (
    SELECT macro_segment, COUNT(DISTINCT User_ID) AS total_users
    FROM segment_map GROUP BY macro_segment
),
seg_agg AS (
    SELECT
        sm.macro_segment,
        sm.product_category_preference                             AS category,
        COUNT(DISTINCT sm.User_ID)                                 AS user_cnt,
        ROUND(AVG(sm.Average_Order_Value), 2)                     AS avg_order,
        ROUND(SUM(sm.Total_Spending), 2)                          AS total_spend,
        RANK() OVER(PARTITION BY sm.macro_segment
                    ORDER BY SUM(sm.Total_Spending) DESC)        AS spend_rank,
        ROUND(COUNT(DISTINCT sm.User_ID) * 100.0
              / ss.total_users, 2)                                AS penetration_pct,
        RANK() OVER(PARTITION BY sm.macro_segment
                    ORDER BY COUNT(DISTINCT sm.User_ID) DESC)   AS pene_rank
    FROM segment_map sm
    JOIN seg_size ss ON sm.macro_segment = ss.macro_segment
    GROUP BY sm.macro_segment, sm.product_category_preference, ss.total_users
)
SELECT * FROM seg_agg
WHERE spend_rank <= 3
ORDER BY macro_segment, spend_rank;


-- 8.区域交叉分析
-- 定义CTE：seg_map，用于将RFM细分客户映射为宏观客户群体，并关联用户地域
WITH seg_map AS (
    SELECT
        -- 根据RFM客户细分类型映射到宏观客户群体
        CASE
            WHEN r.customer_segment IN ('重要价值客户','重要唤回客户')   THEN '核心客户'
            WHEN r.customer_segment IN ('重要深耕客户','重要挽留客户') THEN '重要客户'
            WHEN r.customer_segment  = '潜力客户'                        THEN '潜力客户'
            WHEN r.customer_segment IN ('一般维持客户','新客户')         THEN '一般客户'
            ELSE '流失客户'
        END AS macro_segment,          -- 映射后的宏观群体
        u.Location,                    -- 用户所在地区
        u.User_ID                       -- 用户ID（用于计数）
    FROM rfm_customer_segment r
    JOIN user_personalized_features u ON u.User_ID = r.User_ID   -- 关联用户特征表以获取Location
)
-- 主查询：按地区、宏观群体分组统计用户数及占比
SELECT
    Location,                          -- 地区
    macro_segment,                      -- 宏观客户群体
    COUNT(User_ID)                                                    AS user_count,   -- 该地区该群体用户数
    -- 计算该群体在该地区的用户数占比（百分比，保留两位小数）
    ROUND(COUNT(User_ID) * 100.0
          / SUM(COUNT(User_ID)) OVER(PARTITION BY Location), 2)  AS pct_in_location   -- 群体人数占地区总人数百分比
FROM seg_map
GROUP BY Location, macro_segment         -- 按地区和宏观群体分组
ORDER BY Location, pct_in_location DESC; -- 先按地区，再按该地区内占比降序排列


--9. rfm_main.csv
SELECT
    u.User_ID,
    u.Age,
    u.Gender,
    u.Location,
    u.Income,
    u.Interests,
    u.Last_Login_Days_Ago,
    u.Purchase_Frequency,
    u.Average_Order_Value,
    u.Total_Spending,
    u.Product_Category_Preference,
    u.Time_Spent_on_Site_Minutes,
    u.Pages_Viewed,
    u.Newsletter_Subscription,
    r.RFM_score,
    r.Recency,
    r.Frequency,
    r.Monetary,
    r.customer_segment,
    -- 5分类（方便Tableau颜色分组）
    CASE
        WHEN r.customer_segment IN ('重要价值客户','重要唤回客户')   THEN '核心客户'
        WHEN r.customer_segment IN ('重要深耕客户','重要挽留客户') THEN '重要客户'
        WHEN r.customer_segment  = '潜力客户'                        THEN '潜力客户'
        WHEN r.customer_segment IN ('一般维持客户','新客户')         THEN '一般客户'
        ELSE '流失客户'
    END AS macro_segment
FROM user_personalized_features u
JOIN rfm_customer_segment r ON u.User_ID = r.User_ID;
