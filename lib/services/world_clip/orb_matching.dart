import 'package:opencv_dart/opencv_dart.dart' as cv;

/// One Lowe-filtered ORB correspondence, copied out to plain values so it
/// stays valid after the native match vectors are disposed.
class OrbMatch {
  const OrbMatch(this.queryIdx, this.trainIdx);
  final int queryIdx;
  final int trainIdx;
}

/// ORB keypoints for a (query, train) frame pair plus their Lowe's-ratio
/// filtered matches. Owns the two native keypoint vectors — call [dispose]
/// when done.
class OrbMatches {
  OrbMatches(this.queryKeypoints, this.trainKeypoints, this.good);

  /// Keypoints of the first ([orbGoodMatches]' `queryGray`) frame, indexed by
  /// [OrbMatch.queryIdx].
  final cv.VecKeyPoint queryKeypoints;

  /// Keypoints of the second (`trainGray`) frame, indexed by
  /// [OrbMatch.trainIdx].
  final cv.VecKeyPoint trainKeypoints;

  final List<OrbMatch> good;

  void dispose() {
    queryKeypoints.dispose();
    trainKeypoints.dispose();
  }
}

/// The shared ORB detect → describe → brute-force-Hamming knn → Lowe's ratio
/// pipeline used by both glare-fusion alignment and the frame analyzer's
/// translation fallback (they diverge only in what they fit to the matches
/// afterwards). Returns null — rather than throwing — when either frame has
/// fewer than [minKeypoints] keypoints, either descriptor set is empty, or
/// any native call fails (e.g. features2d missing from the native build), so
/// one bad frame never sinks the caller's whole pass. The caller owns the
/// returned [OrbMatches] and must dispose it.
OrbMatches? orbGoodMatches(
  cv.Mat queryGray,
  cv.Mat trainGray, {
  required int nFeatures,
  required int minKeypoints,
}) {
  cv.ORB? orb;
  cv.BFMatcher? matcher;
  cv.VecKeyPoint? queryKp, trainKp;
  cv.VecVecDMatch? knn;
  final mats = <cv.Mat>[];
  cv.Mat track(cv.Mat m) {
    mats.add(m);
    return m;
  }

  try {
    orb = cv.ORB.create(nFeatures: nFeatures);
    final query = orb.detectAndCompute(queryGray, track(cv.Mat.empty()));
    queryKp = query.$1;
    final queryDesc = track(query.$2);
    final train = orb.detectAndCompute(trainGray, track(cv.Mat.empty()));
    trainKp = train.$1;
    final trainDesc = track(train.$2);
    if (queryKp.length < minKeypoints ||
        trainKp.length < minKeypoints ||
        queryDesc.isEmpty ||
        trainDesc.isEmpty) {
      return null;
    }

    matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
    knn = matcher.knnMatch(queryDesc, trainDesc, 2);
    final good = <OrbMatch>[];
    for (final pair in knn) {
      // Lowe's ratio test: a true match is markedly closer than the runner-up.
      if (pair.length < 2) continue;
      if (pair[0].distance < 0.75 * pair[1].distance) {
        good.add(OrbMatch(pair[0].queryIdx, pair[0].trainIdx));
      }
    }

    final result = OrbMatches(queryKp, trainKp, good);
    queryKp = null; // ownership transferred to the result
    trainKp = null;
    return result;
  } catch (_) {
    return null;
  } finally {
    orb?.dispose();
    matcher?.dispose();
    knn?.dispose();
    queryKp?.dispose();
    trainKp?.dispose();
    for (final m in mats) {
      m.dispose();
    }
  }
}
