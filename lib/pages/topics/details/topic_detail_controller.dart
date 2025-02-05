import 'package:get/get.dart';
import 'package:linux_do/const/app_const.dart';
import 'package:linux_do/controller/base_controller.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/widgets.dart';
import '../../../models/topic_detail.dart';
import '../../../net/api_service.dart';
import '../../../utils/log.dart';
import '../../../utils/mixins/toast_mixin.dart';
import '../../../utils/storage_manager.dart';
import '../../../routes/app_pages.dart';
import 'dart:async';
import 'dart:math';
import 'dart:convert';

class TopicDetailController extends BaseController with WidgetsBindingObserver {
  final topicId = 0.obs;
  final topic = Rx<TopicDetail?>(null);
  final hasMore = true.obs;
  final hasPrevious = true.obs;
  final isLoadingMore = false.obs;
  final isLoadingPrevious = false.obs;
  // 用于控制初始滚动位置
  final initialScrollIndex = 0.obs;

  final ApiService apiService = Get.find();
  // 添加ScrollablePositionedList需要的控制器
  final itemScrollController = ItemScrollController();
  final itemPositionsListener = ItemPositionsListener.create();

  // 存储上次访问的帖子编号
  String get _topicPostKey => 'topic_post_${topicId.value}';

  // 存储已加载的post ids，用于避免重复加载
  final Set<int> loadedPostIds = {};

  // 是否正在发送
  final isSending = false.obs;

  // 阅读时间追踪相关变量
  final _lastTrackTime = DateTime.now().obs;
  final _visiblePostNumbers = <int>{}.obs;
  Timer? _debounceTimer;
  static const _debounceDelay = Duration(milliseconds: 1000); // 1秒防抖延迟

  // 用于存储帖子树结构
  final replyTree = <PostNode>[].obs;

  // 存储点赞状态的Map
  final likedPosts = <int, bool>{}.obs;
  final postScores = <int, int>{}.obs;

  // 回复相关
  final replyContent = ''.obs;
  final isReplying = false.obs;
  final replyToPostNumber = Rx<int?>(null);
  final replyPostTitle = Rx<String?>(null);
  final clientId = DateTime.now().millisecondsSinceEpoch.toString();
  Timer? _presenceTimer;
  Timer? _draftTimer;

  // 控制 _buildFooder 的可见性
  final isFooderVisible = false.obs;

  // 记录开始回复的时间
  final _replyStartTime = DateTime.now().millisecondsSinceEpoch.obs;
  // 记录最后一次输入的时间
  final _lastTypingTime = DateTime.now().millisecondsSinceEpoch.obs;

  /// 是否正在节流
  bool _isThrottling = false;

  @override

  void onInit() {
    super.onInit();
    topicId.value = Get.arguments as int;
    itemPositionsListener.itemPositions.addListener(_onScroll);
    fetchTopicDetail();
    // 添加应用生命周期监听
    WidgetsBinding.instance.addObserver(this);

    // 监听topic变化，重建回复树
    ever(topic, (_) => _buildReplyTree());

    // 初始化点赞数据
    ever(topic, (_) => _initPostScores());

    // 启动在线状态更新定时器
    _startPresenceTimer();

    // 启动草稿保存定时器
    // 暂时不保存草稿
    // _startDraftTimer();
  }

  @override
  void onClose() {
    _debounceTimer?.cancel();
    itemPositionsListener.itemPositions.removeListener(_onScroll);
    // 移除应用生命周期监听
    WidgetsBinding.instance.removeObserver(this);
    // 页面关闭前发送一次计时
    _updateTopicTiming();
    _presenceTimer?.cancel();
    _draftTimer?.cancel();
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 应用回到前台时更新
      _updateTopicTiming();
    } else if (state == AppLifecycleState.paused) {
      // 应用进入后台前更新
      _updateTopicTiming();
    }
  }

  void _debouncedUpdateTiming() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      _updateTopicTiming();
    });
  }

  void _onScroll() {


    if (_isThrottling) return;
    _isThrottling = true;

    Future.delayed(const Duration(milliseconds: 550), () {
      _isThrottling = false;
    });


    final positions = itemPositionsListener.itemPositions.value.toList();
    if (positions.isEmpty) return;

    positions.sort((a, b) => a.index.compareTo(b.index));
    final visiblePosts = <int>{};

    // 收集所有可见帖子的编号
    for (var position in positions) {
      if (position.index >= 1 && position.index - 1 < replyTree.length) {
        final node = replyTree[position.index - 1];
        if (node.post.postNumber != null) {
          visiblePosts.add(node.post.postNumber!);
        }
      }
    }

    // 更新可见帖子集合
    _visiblePostNumbers.value = visiblePosts;

    // 保存最后阅读的帖子编号
    if (visiblePosts.isNotEmpty) {
      StorageManager.setData(_topicPostKey, visiblePosts.reduce(max));
    }

    // 滚动停止时更新阅读时间
    _debouncedUpdateTiming();

    // 检查是否需要加载更多
    if (positions.isNotEmpty) {
      // 检查是否需要向上加载
      final firstVisibleItem = positions.first;
      if (firstVisibleItem.itemLeadingEdge <= 0.1 && 
          firstVisibleItem.index <= 3 && 
          !isLoadingPrevious.value && 
          hasPrevious.value) {
        l.d('触发向上加载: ${firstVisibleItem.index}');
        loadPrevious();
      }

      // 检查是否需要向下加载
      final lastVisibleItem = positions.last;
      final actualLastIndex = lastVisibleItem.index - 1;
      if (lastVisibleItem.itemTrailingEdge >= 0.9 &&
          actualLastIndex >= replyTree.length - 5 &&
          !isLoadingMore.value &&
          hasMore.value) {
        l.d('触发向下加载: ${lastVisibleItem.index}');
        loadMore();
      }
    }
  }

  // 更新阅读时间
  Future<void> _updateTopicTiming() async {
    final visiblePosts = _visiblePostNumbers.value;
    if (visiblePosts.isEmpty) return;

    final now = DateTime.now();
    final timeSpent = now.difference(_lastTrackTime.value).inSeconds;
    if (timeSpent <= 0) return;

    try {
      // 构建计时映射，为每个可见的帖子记录阅读时间
      final timings = {
        for (var postNumber in visiblePosts) postNumber.toString(): timeSpent
      };

      await apiService.updateTopicTiming(
        topicId.value.toString(),
        timeSpent,
        timings,
      );

      l.d('阅读时间更新: $timings');

      _lastTrackTime.value = now;
    } catch (e) {
      l.e('更新阅读时间失败: $e');
    }
  }

  /// 向上加载 获取更早的帖子
  /// 还有问题!!!
  Future<void> loadPrevious() async {
    if (!hasPrevious.value || isLoadingPrevious.value) return;

    try {
      isLoadingPrevious.value = true;

      final currentStream = topic.value?.postStream?.stream ?? [];
      final currentPosts = topic.value?.postStream?.posts ?? [];

      if (currentStream.isEmpty || currentPosts.isEmpty) {
        return;
      }

      // 找到"可见区域最顶上"这条帖子的唯一标识
      // （因为 index=0 是顶部加载指示器，所以真正的第一条帖子一般是 index=1）
      final positions = itemPositionsListener.itemPositions.value.toList();
      positions.sort((a, b) => a.index.compareTo(b.index));
      final firstVisibleIndex = positions.first.index;
      // 这个索引对应当前Posts里的下标 = firstVisibleIndex - 1
      final targetIndexInArray = firstVisibleIndex - 1;

      // 边界保护：确保不越界
      Post? targetPost;
      if (targetIndexInArray >= 0 && targetIndexInArray < currentPosts.length) {
        targetPost = currentPosts[targetIndexInArray];
      }

      // 计算第一个已加载的帖子在stream中的位置
      final firstLoadedPostIndex = currentStream.indexOf(currentPosts.first.id ?? 0);

      if (firstLoadedPostIndex <= 0) {
        l.d('没有更早的帖子了');
        hasPrevious.value = false;
        return;
      }

      // 获取之前20个未加载的post ids
      final previousPostIds = <int>[];
      var index = firstLoadedPostIndex - 1;
      while (index >= 0 && previousPostIds.length < 20) {
        final postId = currentStream[index];
        if (!loadedPostIds.contains(postId)) {
          previousPostIds.insert(0, postId);
          l.d('待加载的ID: $postId');
        } else {
          l.d('ID已加载过: $postId');
        }
        index--;
      }

      if (previousPostIds.isEmpty) {
        hasPrevious.value = false;
        return;
      }

      // 请求获取新的帖子数据
      final response = await apiService.getTopicPosts(
        topicId.value.toString(),
        postIds: previousPostIds.map((id) => id.toString()).toList(),
      );

      // 合并帖子数据
      final newPosts = response.postStream?.posts ?? [];

      if (newPosts.isEmpty) {
        hasPrevious.value = false;
        return;
      }

      // 记录新加载的post ids
      loadedPostIds.addAll(newPosts.map((p) => p.id ?? 0));

      // 先注释掉 暂时不确定接口是否按照时间排序的
      // newPosts.sort((a, b) => a.postNumber!.compareTo(b.postNumber!));

      // 在列表前面插入新加载的帖子
      topic.update((val) {
        val?.postStream?.posts?.insertAll(0, newPosts);
      });

      // 重新定位到插入前的"第一可见帖"
      if (targetPost != null) {
        Future.microtask(() {
          final updatedPosts = topic.value?.postStream?.posts ?? [];
          // 找到原来那条帖子下标
          final newIndex =
              updatedPosts.indexWhere((p) => p.id == targetPost?.id);

          // 因为第0位是"顶部加载指示器"，帖子索引要 +1
          if (newIndex >= 0) {
            final scrollIndex = newIndex + 1;
            itemScrollController.jumpTo(index: scrollIndex);
          }
        });
      }

      // 再根据 stream 判断是否还有更早的帖子
      hasPrevious.value = index >= 0;
    } catch (e) {
      l.e('加载之前的帖子失败: $e');
    } finally {
      isLoadingPrevious.value = false;
    }
  }

  Future<void> fetchTopicDetail() async {
    try {
      isLoading.value = true;
      clearError();

      // 获取上次浏览的位置
      final lastPostNumber = StorageManager.getInt(_topicPostKey);
      final page = lastPostNumber != null ? "/$lastPostNumber" : "/1";

      final response = await apiService.getTopicDetail(
        topicId.value.toString(),
        page: page,
      );

      // 记录已加载的post ids
      final posts = response.postStream?.posts ?? [];
      final stream = response.postStream?.stream ?? [];
      loadedPostIds.addAll(posts.map((p) => p.id ?? 0));

      topic.value = response;

      // 根据stream和当前加载的posts判断是否还有更多
      hasMore.value =
          stream.isNotEmpty && (posts.isEmpty || stream.last != posts.last.id);

      // 判断是否有更早的帖子
      if (posts.isNotEmpty && stream.isNotEmpty) {
        final firstLoadedPostIndex = stream.indexOf(posts.first.id ?? 0);
        hasPrevious.value = firstLoadedPostIndex > 0;
      }

      // 设置初始滚动位置
      if (posts.isNotEmpty && lastPostNumber != null) {
        // 查找上次浏览的帖子在列表中的位置
        final index =
            posts.indexWhere((post) => post.postNumber == lastPostNumber);
        if (index != -1) {
          initialScrollIndex.value = index + 1; // +1考虑顶部的加载指示器
          // 延迟执行滚动，确保列表已经构建完成
          Future.delayed(const Duration(milliseconds: 100), () {
            itemScrollController.jumpTo(index: initialScrollIndex.value);
          });
        }
      }
    } catch (e) {
      l.e('获取帖子详情失败: $e');
      setError('获取帖子详情失败');
    } finally {
      isLoading.value = false;
    }
  }

  /// 加载更多
  Future<void> loadMore() async {
    if (!hasMore.value || isLoadingMore.value) return;

    try {
      isLoadingMore.value = true;

      final currentStream = topic.value?.postStream?.stream ?? [];
      final currentPosts = topic.value?.postStream?.posts ?? [];
      if (currentStream.isEmpty || currentPosts.isEmpty) return;

      // 获取最后一个帖子的ID
      final lastPost = currentPosts.last;
      final lastLoadedPostIndex = currentStream.indexOf(lastPost.id ?? 0);
      if (lastLoadedPostIndex == -1) return;

      l.d('当前最后一个帖子ID: ${lastPost.id}, postNumber: ${lastPost.postNumber}');

      // 获取后续20个未加载的post ids
      final nextPostIds = <int>[];
      var index = lastLoadedPostIndex + 1;
      while (index < currentStream.length && nextPostIds.length < 20) {
        final postId = currentStream[index];
        if (!loadedPostIds.contains(postId)) {
          nextPostIds.add(postId);
          l.d('待加载的ID: $postId');
        }
        index++;
      }

      if (nextPostIds.isEmpty) {
        hasMore.value = false;
        return;
      }

      final response = await apiService.getTopicPosts(
        topicId.value.toString(),
        postIds: nextPostIds.map((id) => id.toString()).toList(),
      );

      // 合并帖子数据
      final newPosts = response.postStream?.posts ?? [];
      if (newPosts.isEmpty) {
        hasMore.value = false;
        return;
      }

      // 记录新加载的post ids
      loadedPostIds.addAll(newPosts.map((p) => p.id ?? 0));

      // 添加新加载的帖子
      topic.update((val) {
        if (val?.postStream?.posts != null) {
          // 按照stream中的顺序添加新帖子
          for (var postId in nextPostIds) {
            final newPost = newPosts.firstWhere((p) => p.id == postId);
            val!.postStream!.posts!.add(newPost);
          }
        }
      });

      // 重新构建回复树
      _buildReplyTree();

      // 更新是否还有更多
      hasMore.value = index < currentStream.length;

      // 强制更新UI
      replyTree.refresh();

      l.d('加载完成，当前帖子数: ${topic.value?.postStream?.posts?.length}, 最后一个帖子编号: ${topic.value?.postStream?.posts?.last.postNumber}');
    } catch (e) {
      l.e('加载更多失败: $e');
    } finally {
      isLoadingMore.value = false;
    }
  }

  Future<void> refreshTopicDetail() async {
    loadedPostIds.clear();
    await fetchTopicDetail();
  }

  void launchUrl(String url) {
    if (url.isEmpty) return;
    Get.toNamed(Routes.WEBVIEW, arguments: url);
  }

  // 构建帖子树结构
  void _buildReplyTree() {
    if (topic.value?.postStream?.posts == null) return;

    final posts = topic.value!.postStream!.posts!;
    final Map<int?, List<Post>> replyMap = {};

    // 按照回复对象分组
    for (var post in posts) {
      final replyTo = post.replyToPostNumber;
      if (!replyMap.containsKey(replyTo)) {
        replyMap[replyTo] = [];
      }
      replyMap[replyTo]!.add(post);
    }

    // 直接使用原始帖子列表构建树，保持原始顺序
    replyTree.value = posts.map((post) {
      final replies = replyMap[post.postNumber] ?? [];
      return PostNode(post, replies.map((reply) => PostNode(reply)).toList());
    }).toList();

    l.d('构建树完成，节点数量: ${replyTree.length}');
  }

  // 点赞/取消点赞
  void toggleLike(Post post) async {
    if (post.id == null || post.postNumber == null) return;

    try {
      // 先更新UI状态
      final postNumber = post.postNumber!;
      final isLiked = likedPosts[postNumber] ?? false;
      
      // 更新点赞状态
      likedPosts[postNumber] = !isLiked;

      // 更新点赞数
      final currentScore = postScores[postNumber] ?? 0;
      postScores[postNumber] = currentScore + (isLiked ? -1 : 1);

      // 调用API
      final response = await apiService.togglePostLike(post.id.toString());
      
      // 根据API响应更新状态
      // 从 actions_summary 中找到点赞动作（id=2）的状态
      final likeAction = response.actionsSummary?.firstWhere(
        (action) => action.id == 2,
        orElse: () => ActionSummary(id: 2, canAct: true),
      );
      
      // 更新点赞状态和数量
      likedPosts[postNumber] = !(likeAction?.canAct ?? true); // 如果 can_act 为 false，说明已经点赞
      postScores[postNumber] = response.score?.toInt() ?? 0;

      l.d('${isLiked ? "取消点赞" : "点赞"} #$postNumber');
    } catch (e) {
      // 发生错误时恢复原状态
      final postNumber = post.postNumber!;
      final isLiked = likedPosts[postNumber] ?? false;
      
      likedPosts[postNumber] = !isLiked;
      final currentScore = postScores[postNumber] ?? 0;
      postScores[postNumber] = currentScore + (isLiked ? 1 : -1);
      
      l.e('点赞失败: $e');
    }
  }

  // 获取帖子的点赞数
  int getPostScore(Post post) {
    if (post.postNumber == null) return 0;
    return postScores[post.postNumber!] ?? 0;
  }

  // 获取帖子是否已点赞
  bool isPostLiked(Post post) {
    if (post.postNumber == null) return false;
    return likedPosts[post.postNumber!] ?? false;
  }

  // 初始化点赞数据
  void _initPostScores() {
    if (topic.value?.postStream?.posts != null) {
      for (var post in topic.value!.postStream!.posts!) {
        if (post.postNumber != null) {
          postScores[post.postNumber!] = post.reactionUsersCount ?? 0;
          // 使用 currentUserReaction 判断是否已点赞
          likedPosts[post.postNumber!] = post.currentUserReaction != null;
        }
      }
    }
  }

  // 开始回复
  void startReply([int? postNumber, String? title]) {
    replyToPostNumber.value = postNumber;
    replyPostTitle.value = title;
    isReplying.value = true;
    _replyStartTime.value = DateTime.now().millisecondsSinceEpoch;
    _lastTypingTime.value = _replyStartTime.value;
  }

  // 取消回复
  void cancelReply() {
    replyContent.value = '';
    replyToPostNumber.value = null;
    replyPostTitle.value = null;
    isReplying.value = false;
  }

  // 更新打字时间
  void updateTypingTime() {
    _lastTypingTime.value = DateTime.now().millisecondsSinceEpoch;
  }

  // 发送回复
  Future<void> sendReply() async {
    final content = replyContent.value.trim();
    if (content.isEmpty) return;

    try {
      isSending.value = true;

      // 先不计算打字时间了
      final now = DateTime.now().millisecondsSinceEpoch;
      final typingDuration = now - _lastTypingTime.value;
      final composerDuration = now - _replyStartTime.value;

      // 发送回复
      final response = await apiService.replyPost(
        topicId.value.toString(),
        content,
        true,
        'regular',
        '',
        replyToPostNumber: replyToPostNumber.value,
      );

      showSnackbar(
          title: AppConst.commonTip,
          message: AppConst.posts.replySuccess,
          type: SnackbarType.success);

      // 清空回复内容
      replyContent.value = '';
      replyToPostNumber.value = null;
      replyPostTitle.value = null;
      isReplying.value = false;

      // 刷新帖子列表
      await refreshTopicDetail();

      // 滚动到新回复
      if (response.post.postNumber != null) {
        final posts = topic.value?.postStream?.posts ?? [];
        final index =
            posts.indexWhere((p) => p.postNumber == response.post.postNumber);
        if (index != -1) {
          itemScrollController.scrollTo(
            index: index + 1,
            duration: const Duration(milliseconds: 300),
          );
        }
      }
    } catch (e, s) {
      l.e('发送回复失败: $e -  \n$s');
      showSnackbar(
          title: AppConst.commonTip,
          message: AppConst.posts.replyFailed,
          type: SnackbarType.error);
    } finally {
      isSending.value = false;
    }
  }

  // 启动在线状态更新定时器
  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isReplying.value) {
        apiService.updateChannelPresence(
          clientId,
          '/discourse-presence/reply/${topicId.value}',
        );
      }
    });
  }

  // 启动草稿保存定时器
  // 暂时不保存草稿
  // ignore: unused_element
  void _startDraftTimer() {
    _draftTimer?.cancel();
    _draftTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (isReplying.value && replyContent.value.isNotEmpty) {
        final data = jsonEncode({
          'reply': replyContent.value,
          'action': 'reply',
          'categoryId': topic.value?.categoryId ?? 0,
          'tags': [],
          'archetypeId': 'regular',
          'metaData': null,
          'composerTime': DateTime.now().millisecondsSinceEpoch,
          'typingTime': 2400,
        });

        apiService.saveDraft(
          'topic_${topicId.value}',
          0,
          data,
          clientId,
          false,
        );
      }
    });
  }
}

// 帖子节点类

class PostNode {
  final Post post;
  final List<PostNode> children;

  PostNode(this.post, [this.children = const []]);
}
