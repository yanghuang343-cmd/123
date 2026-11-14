import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import process from 'node:process';

const SETTINGS = JSON.parse(await fs.readFile(path.resolve('config/miaoshou-jp.json'), 'utf8'));
const DATA = SETTINGS.dataDirectory;
const CREDENTIALS = path.join(process.env.USERPROFILE ?? 'C:\\Users\\faida', '.codex', 'skills', 'miaoshou-erp-common-collectbox-manage', 'resources', 'config.json');
const SHOP_ID = SETTINGS.shopId;
const SHOP_NAME = SETTINGS.shopName;
const BASE = 'https://openapi-erp.91miaoshou.com';
const COMMON_LIST = '/open/v1/product/common_collect_box/common_collect_box/get_common_collect_box_list';
const COMMON_DETAIL = '/open/v1/product/common_collect_box/common_collect_box/get_common_collect_box_detail';
const CLAIM_COMMON = '/open/v1/product/common_collect_box/common_collect_box/claimed';
const TK_LIST = '/open/v1/product/collect_box/tiktok/collect_box/search_collect_box_detail_list';
const TK_DETAIL = '/open/v1/product/collect_box/tiktok/collect_box/get_shop_collect_item_info';
const TK_SAVE = '/open/v1/product/collect_box/tiktok/collect_box/save_shop_collect_item_info';
const SHOP_LIST = '/open/v1/product/shop/shop/get_shop_list';
const TK_CLAIM_SHOP = '/open/v1/product/collect_box/tiktok/collect_box/claim_to_shop';
const TK_PUBLISH = '/open/v1/product/collect_box/tiktok/collect_box/save_move_collect_task';
const PAUSE_FLAG = path.resolve('runs/automation.pause');

function log(message) { console.log(message); }
function arg(name) { const i = process.argv.indexOf(name); return i < 0 ? '' : process.argv[i + 1] ?? ''; }
async function checkpoint() {
  let announced = false;
  while (await fs.stat(PAUSE_FLAG).then(() => true).catch(() => false)) {
    if (!announced) { log('FLOW_PAUSED 已在安全检查点暂停。'); announced = true; }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  if (announced) log('FLOW_RESUMED 已继续。');
}
function unwrap(response, endpoint) {
  const code = String(response?.code ?? '');
  if (!response || !['success', 'SUCCESS'].includes(String(response.result ?? 'success')) || (code && !['0', '200', 'success', 'SUCCESS'].includes(code))) throw new Error(`妙手接口未成功：${endpoint}（${code || '未知错误'}）`);
  return response.data ?? {};
}
async function credentials() {
  const fromEnv = process.env.MIAOSHOU_APP_KEY && process.env.MIAOSHOU_APP_SECRET;
  if (fromEnv) return { app_key: process.env.MIAOSHOU_APP_KEY, app_secret: process.env.MIAOSHOU_APP_SECRET, base_url: process.env.MIAOSHOU_BASE_URL || BASE };
  try { return JSON.parse(await fs.readFile(CREDENTIALS, 'utf8')); }
  catch { throw new Error('找不到本地妙手 API 授权。请先在妙手 ERP 技能配置中完成授权。'); }
}
async function api(endpoint, body = {}) {
  await checkpoint();
  const cfg = await credentials();
  if (!cfg.app_key || !cfg.app_secret) throw new Error('本地妙手 API 授权信息不完整。');
  const bodyJson = JSON.stringify(body);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const sign = crypto.createHmac('sha256', cfg.app_secret).update(`${cfg.app_secret}${endpoint}${timestamp}${cfg.app_key}${bodyJson}${cfg.app_secret}`).digest('hex');
  const response = await fetch(`${cfg.base_url || BASE}${endpoint}`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-app-key': cfg.app_key, 'x-timestamp': timestamp, 'x-sign': sign }, body: bodyJson
  });
  if (!response.ok) throw new Error(`妙手服务暂不可用：HTTP ${response.status}`);
  return unwrap(await response.json(), endpoint);
}
function listingNames(...sources) {
  const keys = /^(?:brandName|brand_name|brand|shopName|shop_name|storeName|store_name|sellerName|seller_name|sourceShopName|sourceStoreName)$/i;
  const names = new Set();
  const visit = (value) => {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) { for (const item of value) visit(item); return; }
    for (const [key, item] of Object.entries(value)) {
      if (keys.test(key) && typeof item === 'string' && item.trim().length > 1 && item.trim().length < 100) names.add(item.trim());
      else if (item && typeof item === 'object') visit(item);
    }
  };
  for (const source of sources) visit(source);
  return [...names].sort((a, b) => b.length - a.length);
}
function scrub(value, ids = [], labels = []) {
  let text = String(value ?? '');
  text = text.replace(/Amazonベーシック|Amazon Basics/gi, '').replace(/\s{2,}/g, ' ').trim();
  for (const id of ids.filter(Boolean)) text = text.replace(new RegExp(id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), '');
  for (const label of labels.filter(Boolean)) {
    const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const pattern = new RegExp(`(^|[\\s【\\[（(「『])${escaped}(?=$|[\\s】\\]）)」』、,，:：|｜/／-])`, 'giu');
    text = text.replace(pattern, '$1');
  }
  text = text.replace(/(?:原産国|原産地|产地|原产国|製造国|country of origin|made in)\s*[:：]?[^\n\r。；;]*/gi, '');
  return text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
const blocked = /化粧品|化妆品|スキンケア|美容液|化粧水|食品|飲料|サプリメント|医薬品|医療機器|药品|医药|处方药|cosmetic|skincare|food|beverage|medicine|medical device|prescription/i;
const knownTierOne = /Apple|Nike|Adidas|Disney|LEGO|Sony|Nintendo|Samsung|Dyson|任天堂|ソニー|ナイキ|アディダス|ディズニー|レゴ|サムスン|ダイソン/i;
function entriesOfSkuMap(map) { return map && typeof map === 'object' ? Object.entries(map).filter(([, sku]) => sku && sku.isDelete !== '1' && sku.isDelete !== 1) : []; }
async function findShop() {
  const data = await api(SHOP_LIST, { platform: 'tiktok', site: 'JP', pageNo: 1, pageSize: 100 });
  const shops = data.shopList ?? data.list ?? [];
  const shop = shops.find((entry) => String(entry.shopId) === String(SHOP_ID));
  const shopName = shop?.shopNick ?? shop?.platformShopName;
  if (!shop || shop.platform !== 'tiktok' || shop.site !== 'JP' || shopName !== SHOP_NAME || shop.status !== 'normal') throw new Error(`当前授权店铺核验失败：需要 ${SHOP_NAME}（${SHOP_ID}，JP）。`);
  return shop;
}
async function locateCommon(asin, attempts = 1) {
  for (let n = 0; n < attempts; n += 1) {
    const data = await api(COMMON_LIST, { pageNo: 1, pageSize: 50, filter: { tabPaneName: 'all', sourceItemIdKeyword: asin } });
    const rows = data.detailList ?? [];
    const exact = rows.filter((row) => String(row.itemNum ?? '').toUpperCase() === asin || (row.sourceList ?? []).some((s) => String(s.sourceItemId ?? '').toUpperCase() === asin));
    if (exact.length > 1) throw new Error(`采集箱中找到多个匹配 ${asin} 的商品，请交给 Codex 核对后再继续。`);
    if (exact.length === 1) return exact[0];
    if (n < attempts - 1) await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  throw new Error(`妙手公共采集箱尚未找到 ${asin}。请确认插件已完成采集后重试。`);
}
async function findTkItem(commonId, asin) {
  for (let n = 0; n < 10; n += 1) {
    const data = await api(TK_LIST, { pageNo: 1, pageSize: 50, filter: { status: 'notPublished', sourceItemIdKeyword: asin } });
    const rows = Array.isArray(data) ? data : data.detailList ?? data.list ?? [];
    const found = rows.find((row) => String(row.commonCollectBoxDetailId) === String(commonId));
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  throw new Error('认领已提交，但 TikTok 采集箱暂时没有返回商品；请在妙手采集箱核对状态后再重试。');
}
async function saveReview(item, common, detail, asin, fxRate, finalProduct) {
  await fs.mkdir(path.join(DATA, '商品图片', asin), { recursive: true });
  const output = path.join(DATA, '商品候选资料.json');
  let candidates = [];
  try { candidates = JSON.parse(await fs.readFile(output, 'utf8')); } catch { /* create new list */ }
  const row = {
    id: asin, sourceUrl: `https://www.amazon.co.jp/dp/${asin}`, sourceMethod: 'miaoshou_browser_plugin',
    title: finalProduct.title, description: finalProduct.notes, category: String(finalProduct.cid ?? ''), price: String(Math.round(Number(common.price) * 2.5 * fxRate)), brandName: finalProduct.brandName ?? '',
    brandStatus: finalProduct.brandName ? 'identified_brand' : 'confirmed_unbranded', productImages: finalProduct.localImagePaths?.length ? finalProduct.localImagePaths : finalProduct.imgUrls ?? [], skuMap: finalProduct.skuMap ?? {},
    stock: SETTINGS.stockPerSku, packageWeightG: SETTINGS.packageWeightKg * 1000, packageDimensionsCm: { length: SETTINGS.packageLengthCm, width: SETTINGS.packageWidthCm, height: SETTINGS.packageHeightCm }, sourcePriceCny: { min: common.price ?? '' },
    priceFormula: { multiplier: SETTINGS.priceMultiplier, cnyToJpyRate: fxRate }, importMeta: { commonId: common.commonCollectBoxDetailId, tiktokId: item.collectBoxDetailId, shopId: SHOP_ID, gmtModified: new Date().toISOString() },
    preflightStatus: 'CODEX_REVIEW_REQUIRED'
  };
  candidates = candidates.filter((x) => x.id !== asin); candidates.push(row);
  await fs.writeFile(output, `${JSON.stringify(candidates, null, 2)}\n`, 'utf8');
  const review = { asin, commonId: common.commonCollectBoxDetailId, detailId: item.collectBoxDetailId, shop: SHOP_NAME, shopId: SHOP_ID, status: 'CODEX_REVIEW_REQUIRED', category: finalProduct.cid, title: finalProduct.title, skuCount: entriesOfSkuMap(finalProduct.skuMap).length, priceBasisCny: common.price, fxRateCnyToJpy: fxRate, imageCount: finalProduct.imgUrls?.length ?? 0, next: 'Codex 核对类目、日文文案、商品图片及价格依据；确认后点击“提交到 TikTok”。' };
  const reviewPath = path.join(path.dirname(output), 'Codex复核队列.json');
  let queue = [];
  try { queue = JSON.parse(await fs.readFile(reviewPath, 'utf8')); } catch { /* create queue */ }
  queue = queue.filter((x) => x.asin !== asin); queue.push(review);
  await fs.writeFile(reviewPath, `${JSON.stringify(queue, null, 2)}\n`, 'utf8');
  log(`CODEX_REVIEW_REQUIRED ${asin} ${path.join(DATA, 'Codex复核队列.json')}`);
}
async function downloadImages(asin, urls) {
  const folder = path.join(DATA, '商品图片', asin);
  await fs.mkdir(folder, { recursive: true });
  const paths = [];
  for (let i = 0; i < urls.length; i += 1) {
    try {
      const response = await fetch(urls[i], { signal: AbortSignal.timeout(12000) });
      if (!response.ok) continue;
      const type = response.headers.get('content-type') ?? '';
      const ext = /png/i.test(type) ? 'png' : /webp/i.test(type) ? 'webp' : /gif/i.test(type) ? 'gif' : 'jpg';
      const filename = path.join(folder, `${String(i + 1).padStart(2, '0')}.${ext}`);
      await fs.writeFile(filename, Buffer.from(await response.arrayBuffer()));
      paths.push(filename);
    } catch { /* Keep the ERP image URL if its source cannot be downloaded locally. */ }
  }
  return paths;
}

async function prepare() {
  const asin = String(arg('--asin')).toUpperCase();
  if (!/^[A-Z0-9]{10}$/.test(asin)) throw new Error('请输入 Amazon.co.jp 商品页的 10 位 ASIN。');
  const shop = await findShop();
  log(`店铺已确认：${shop.shopNick ?? shop.platformShopName}（JP）。正在查找公共采集箱…`);
  const commonRow = await locateCommon(asin, 6);
  const common = await api(COMMON_DETAIL, { commonCollectBoxDetailId: commonRow.commonCollectBoxDetailId });
  const fullText = `${common.title ?? ''} ${common.notesText ?? ''} ${common.notes ?? ''} ${common.categoryName ?? ''}`;
  if (blocked.test(fullText)) throw new Error('该商品命中禁采类别，流程已停止，未认领。');
  if (knownTierOne.test(fullText)) throw new Error('商品可能涉及一线品牌，流程已停止，未认领。');
  const existing = commonRow.status === 'claimed' || commonRow.platformCollectBoxDetailId;
  if (!existing) {
    log('商品符合初步筛查，正在认领到 TikTok 采集箱…');
    await api(CLAIM_COMMON, { detailSerialNumberPlatformList: [{ detailId: commonRow.commonCollectBoxDetailId, platform: 'tiktok', serialNumber: 1 }] });
  }
  const item = await findTkItem(commonRow.commonCollectBoxDetailId, asin);
  const info = await api(TK_DETAIL, { detailId: item.collectBoxDetailId, shopId: SHOP_ID });
  const product = info.shopCollectItemInfo;
  if (!product || !info.ossMd5) throw new Error('妙手没有返回可编辑的店铺商品资料，请交给 Codex 检查。');
  const allText = `${product.title ?? ''} ${product.notes ?? ''}`;
  if (knownTierOne.test(allText)) throw new Error('商品可能涉及一线品牌，流程已停止，未保存商品。');
  if (!String(product.cid ?? '').trim()) throw new Error('商品类目为空；请让 Codex 先选择日本站准确类目。');
  if (!Array.isArray(product.imgUrls) || product.imgUrls.length < 1) throw new Error('商品图片为空，流程暂停。');
  if (!String(product.title ?? '').trim() || !String(product.notes ?? '').trim()) throw new Error('标题或描述为空，交给 Codex 补充。');
  if (!/[\u3040-\u30ff\u4e00-\u9fff]/.test(product.title) || !/[\u3040-\u30ff\u4e00-\u9fff]/.test(product.notes)) throw new Error('标题或描述需要翻译为日文，交给 Codex 处理。');
  const skus = entriesOfSkuMap(product.skuMap);
  if (!skus.length) throw new Error('未找到可发布 SKU，流程暂停。');
  const skuSourcePrices = skus.map(([, sku]) => Number(sku.originPrice)).filter((value) => Number.isFinite(value) && value > 0);
  const sourcePrice = Number(common.price) > 0 ? Number(common.price) : (skuSourcePrices.length ? Math.min(...skuSourcePrices) : NaN);
  if (!Number.isFinite(sourcePrice) || sourcePrice <= 0) throw new Error('妙手未提供有效的人民币采集价，不能按定价公式自动计算。');
  const fx = await fetch('https://open.er-api.com/v6/latest/CNY', { signal: AbortSignal.timeout(12000) }).then((r) => r.json()).catch(() => null);
  const rate = Number(fx?.rates?.JPY);
  if (!Number.isFinite(rate) || rate <= 0) throw new Error('暂时无法取得 CNY/JPY 汇率，请稍后重试或交给 Codex 核算。');
  const ids = [asin, common.itemNum, ...(common.sourceList ?? []).map((x) => x.sourceItemId)];
  const titleLabels = listingNames(product, common);
  const originalTitle = product.title;
  product.title = scrub(product.title, ids, titleLabels);
  if (!product.title) throw new Error('清理品牌或来源店铺名称后标题为空，商品未保存；请交给 Codex 重写标题。');
  product.notes = scrub(product.notes, ids);
  if (product.title !== originalTitle && titleLabels.some((name) => originalTitle.toLocaleLowerCase().includes(name.toLocaleLowerCase()))) {
    log(`标题已清理商品品牌或来源店铺名称：${originalTitle} → ${product.title}`);
  }
  if (/Amazonベーシック|Amazon Basics/i.test(allText)) { product.brandId = ''; product.brandName = ''; }
  const localImagePaths = await downloadImages(asin, product.imgUrls);
  product.weight = SETTINGS.packageWeightKg; product.packageLength = SETTINGS.packageLengthCm; product.packageWidth = SETTINGS.packageWidthCm; product.packageHeight = SETTINGS.packageHeightCm;
  product.deliveryOptionSetType = product.deliveryOptionSetType || 'default';
  for (const [, sku] of skus) {
    const skuPriceCny = Number(sku.originPrice) > 0 ? Number(sku.originPrice) : sourcePrice;
    sku.stock = SETTINGS.stockPerSku; sku.weight = SETTINGS.packageWeightKg; sku.price = Math.max(1, Math.round(skuPriceCny * SETTINGS.priceMultiplier * rate));
  }
  const result = await api(TK_SAVE, { ossMd5: info.ossMd5, detailId: item.collectBoxDetailId, shopId: SHOP_ID, shopCollectItemInfo: product });
  if (!result.ossMd5) throw new Error('商品保存响应缺少版本标识，已停止后续步骤。');
  await api(TK_CLAIM_SHOP, { detailIds: [item.collectBoxDetailId], shopIds: [SHOP_ID] });
  await saveReview(item, { ...common, price: sourcePrice }, product, asin, rate, { ...product, localImagePaths });
}
async function checkSetup() {
  const shop = await findShop();
  log(`SETUP_OK ${shop.shopNick ?? shop.platformShopName} ${shop.site} ${shop.shopId}`);
}
async function publish() {
  const asin = String(arg('--asin')).toUpperCase();
  if (!/^[A-Z0-9]{10}$/.test(asin)) throw new Error('ASIN 格式无效。');
  const file = path.join(DATA, 'Codex复核队列.json');
  const queue = JSON.parse(await fs.readFile(file, 'utf8'));
  const item = queue.find((x) => x.asin === asin && x.status === 'CODEX_REVIEWED');
  if (!item) throw new Error('尚未找到 Codex 已复核标记。请先完成 Codex 复核，再刷新状态。');
  await findShop();
  const list = await api(TK_LIST, { pageNo: 1, pageSize: 50, filter: { status: 'notPublished', sourceItemIdKeyword: asin } });
  const rows = Array.isArray(list) ? list : list.detailList ?? list.list ?? [];
  const product = rows.find((x) => String(x.collectBoxDetailId) === String(item.detailId)) ?? rows.find((x) => String(x.commonCollectBoxDetailId) === String(item.commonId));
  const detailId = Number(product?.collectBoxDetailId);
  if (!Number.isFinite(Number(detailId)) || Number(detailId) <= 0) throw new Error('发布前无法重新确认 TikTok 采集箱商品，请交给 Codex 核对。');
  await api(TK_PUBLISH, { detailIds: [Number(detailId)], shopIds: [SHOP_ID] });
  item.status = 'SUBMITTED'; item.submittedAt = new Date().toISOString(); item.detailId = Number(detailId);
  await fs.writeFile(file, `${JSON.stringify(queue, null, 2)}\n`, 'utf8');
  log(`SUBMITTED ${asin} ${SHOP_NAME}。妙手会异步处理，请在发布列表确认最终状态。`);
}

try {
  if (process.argv.includes('--check-setup')) await checkSetup();
  else if (process.argv.includes('--prepare')) await prepare();
  else if (process.argv.includes('--publish')) await publish();
  else throw new Error('未知运行模式。');
} catch (error) {
  log(`FLOW_ERROR ${error.message}`);
  process.exitCode = 1;
}
