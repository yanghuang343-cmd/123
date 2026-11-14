import fs from 'node:fs/promises';
import path from 'node:path';

const forbidden = [
  ['cosmetics / beauty products', /化粧品|化妆品|化妆|护肤|コスメ|スキンケア|美容液|化粧水|乳液|ファンデーション|粉底|口紅|マスカラ|日焼け止め|香水|ネイルポリッシュ|美容部員|cosmetic|skincare|makeup|beauty product/i],
  ['food / beverages / supplements', /食品|食材|食物|饮料|零食|补充剂|膳食补充|飲料|飲み物|菓子|お菓子|珈琲|コーヒー|スティックコーヒー|サプリメント|健康食品|プロテイン|フード|coffee|food|beverage|dietary supplement/i],
  ['medicines / medical products', /医药|药品|药物|医疗器械|处方药|非处方药|中药|医薬品|医薬部外品|処方薬|市販薬|漢方薬|医療機器|医療用|治療薬|薬剤|medical device|medicine|pharmaceutical|prescription drug/i]
];

function valuesOf(candidate) {
  return [
    candidate.title,
    candidate.description,
    candidate.category,
    ...(Array.isArray(candidate.riskTerms) ? candidate.riskTerms : []),
    ...Object.entries(candidate.attributes ?? {}).flat()
  ].filter((value) => typeof value === 'string').join(' ');
}

export async function inspect(candidate, candidateIndex, inputPath, requiredAttributes = []) {
  const blocked = [];
  const review = [];
  const label = candidate?.id ?? `candidate-${candidateIndex}`;
  if (!candidate || typeof candidate !== 'object') return { id: label, status: 'BLOCKED', reasons: ['Candidate must be an object'] };

  for (const [category, pattern] of forbidden) {
    if (pattern.test(valuesOf(candidate))) blocked.push(`User exclusion: ${category} detected in supplied product text/category`);
  }

  const sourcePrice = Number(candidate.sourcePriceCny?.min);
  const fxRate = Number(candidate.priceFormula?.cnyToJpyRate);
  if (Number.isFinite(sourcePrice) && sourcePrice > 0 && Number.isFinite(fxRate) && fxRate > 0) {
    const expectedPrice = Math.round(sourcePrice * Number(candidate.priceFormula?.multiplier ?? 2.5) * fxRate);
    if (Number(candidate.price) !== expectedPrice) blocked.push(`JPY price does not match the configured source-price formula (expected ${expectedPrice})`);
  } else {
    review.push('Provide a source CNY price and exchange-rate record to apply the required JPY price formula');
  }

  if (!['manual', 'authorized_export', 'authorized_sp_api', 'miaoshou_browser_plugin'].includes(candidate.sourceMethod)) {
    review.push('Confirm the source came from the approved Miaoshou browser plugin or another authorized source');
  }

  if (candidate.inventoryOwnedAndAvailable !== true) blocked.push('Inventory ownership and availability are not confirmed');

  const packageDimensions = candidate.packageDimensionsCm ?? {};
  const sourceDimensions = candidate.sourceProductDimensionsCm ?? {};
  for (const dimension of ['length', 'width', 'height']) {
    if (Number(sourceDimensions[dimension]) > 0 && Number(packageDimensions[dimension]) > 0 && Number(packageDimensions[dimension]) < Number(sourceDimensions[dimension])) {
      blocked.push(`Package ${dimension} is smaller than the known product ${dimension}; verify parcel measurements before listing`);
    }
  }
  if (Number(candidate.sourceWeightG) > 0 && Number(candidate.packageWeightG) > 0 && Number(candidate.packageWeightG) < Number(candidate.sourceWeightG)) {
    blocked.push('Package weight is below the known product weight; verify parcel weight before listing');
  }

  const hasBrand = String(candidate.brandName ?? '').trim().length > 0;
  const brandStatus = String(candidate.brandStatus ?? 'unknown');
  const allowedBrandStatuses = ['china_generic_brand', 'platform_owned_brand', 'identified_brand'];
  if (brandStatus === 'counterfeit_or_infringing') {
    blocked.push('Brand/IP is marked as counterfeit or infringing');
  } else if (!hasBrand && brandStatus !== 'confirmed_unbranded') {
    review.push('Brand status is unknown; classify the product brand before listing');
  } else if (hasBrand && !allowedBrandStatuses.includes(brandStatus)) {
    review.push('Brand source/status is unknown; verify it before listing');
  }

  for (const key of ['title', 'price', 'description', 'category']) {
    if (!String(candidate[key] ?? '').trim() || String(candidate[key]).startsWith('请')) {
      review.push(`Product field needs real data: ${key}`);
    }
  }
  if (candidate.japanLocaleReviewed !== true) review.push('Confirm Japanese title, description, and image text meet TikTok Shop Japan presentation rules');
  for (const name of requiredAttributes) {
    if (!String(candidate.attributes?.[name] ?? '').trim()) review.push(`Missing required TikTok Shop attribute: ${name}`);
  }
  if (!Array.isArray(candidate.productImages) || candidate.productImages.length === 0) {
    review.push('Add at least one product image from the collected product record');
  } else if (inputPath) {
    const base = path.dirname(inputPath);
    for (const image of candidate.productImages) {
      const imagePath = path.resolve(base, image);
      const exists = await fs.stat(imagePath).then((s) => s.isFile()).catch(() => false);
      if (!exists) review.push(`Image file missing: ${image}`);
    }
  }

  const fulfillment = candidate.fulfillmentPlan ?? {};
  if (!fulfillment.method || !Number.isFinite(fulfillment.readyToShipWithinBusinessDays)) {
    review.push('Provide a fulfillment plan that meets TikTok Shop Japan handling deadlines');
  } else if (fulfillment.readyToShipWithinBusinessDays > 2) {
    blocked.push('Planned ready-to-ship time exceeds the current TikTok Shop Japan preparation window');
  }
  if (!String(fulfillment.trackingCarrier ?? '').trim() || fulfillment.carrierApprovedByTikTok !== true) {
    review.push('Confirm the selected carrier is currently approved by TikTok Shop Japan and provides tracking');
  }

  const reasons = [...blocked, ...review];
  return { id: label, status: blocked.length ? 'BLOCKED' : review.length ? 'REVIEW' : 'READY', reasons, candidate };
}
