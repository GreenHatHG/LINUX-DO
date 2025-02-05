import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../routes/app_pages.dart';
import '../../models/search_result.dart';
import '../../controller/base_controller.dart';
import '../../models/topic_model.dart';
import 'tab_views/topic_tab_controller.dart';
import 'tab_views/topic_tab_view.dart';
import '../../net/api_service.dart';
import '../../utils/log.dart';

class TopicsController extends BaseController
    with GetSingleTickerProviderStateMixin {
  final ApiService _apiService = Get.find<ApiService>();

  // 搜索相关控制器和状态
  final searchFocusNode = FocusNode();
  final searchController = TextEditingController();
  final layerLink = LayerLink();
  OverlayEntry? overlayEntry;

  // 帖子列表数据
  final RxList<Topic> topics = <Topic>[].obs;

  // 保存完整的响应数据
  final Rx<SearchResult?> searchResult = Rx<SearchResult?>(null);

  // 搜索状态
  final RxBool isSearching = false.obs;

  // 搜索错误信息
  final RxString searchError = ''.obs;

  // 搜索框焦点状态
  final RxBool isSearchFocused = false.obs;

  // 路径
  final paths = ['latest', 'new', 'unread', 'unseen', 'top', 'hot'];

  // 简单一些，本地定义tab
  final tabs = const [
    Tab(text: '最新'),
    Tab(text: '新帖'),
    Tab(text: '未读'),
    Tab(text: '未看'),
    Tab(text: '排行'),
    Tab(text: '热门')
  ];

  final isRefreshing = false.obs;

  // 底部栏显示状态
  final isBottomBarVisible = true.obs;

  // Tab控制器
  late TabController tabController;

  // 各个标签页的控制器
  final _tabControllers = <String, TopicTabController>{}.obs;

  // 移除 tabViews getter，改用 _buildTabView 方法
  Widget _buildTabView(int index) {
    final path = paths[index];
    return TopicTabView(path: path);
  }

  // 获取所有tab视图
  List<Widget> get tabViews => List.generate(
        paths.length,
        (index) => _buildTabView(index),
        growable: false,
      );

  // 处理滚动通知
  bool handleScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      switch (notification.direction) {
        case ScrollDirection.forward:
          // 向上滚动，显示底部栏
          if (!isBottomBarVisible.value) {
            isBottomBarVisible.value = true;
          }
          break;
        case ScrollDirection.reverse:
          // 向下滚动，隐藏底部栏
          if (isBottomBarVisible.value) {
            isBottomBarVisible.value = false;
          }
          break;
        case ScrollDirection.idle:
          break;
      }
    }
    return false;
  }

  TopicsController();

  @override
  void onInit() {
    super.onInit();
    tabController = TabController(length: tabs.length, vsync: this);
    tabController.addListener(_handleTabChange);
    // 只初始化当前tab的controller
    _initTabController(paths[tabController.index]);

    // 添加搜索框焦点监听
    searchFocusNode.addListener(_onSearchFocusChange);
  }

  void _handleTabChange() {
    if (!tabController.indexIsChanging) return;
    final path = paths[tabController.index];
    _initTabController(path);
  }

  void _initTabController(String path) {
    // 如果controller已经存在，不需要重新创建
    if (_tabControllers.containsKey(path)) return;

    final controller = TopicTabController(path: path);
    _tabControllers[path] = controller;
    Get.put(controller, tag: path);
  }

  @override
  void onClose() {
    removeSearchResults();
    searchFocusNode.removeListener(_onSearchFocusChange);
    searchFocusNode.dispose();
    searchController.dispose();
    tabController.removeListener(_handleTabChange);
    tabController.dispose();
    // 清理所有controller
    for (final controller in _tabControllers.values) {
      Get.delete<TopicTabController>(tag: controller.path);
    }
    _tabControllers.clear();
    super.onClose();
  }

  void _onSearchFocusChange() {
    if (!searchFocusNode.hasFocus) {
      removeSearchResults();
    } else if (searchController.text.isNotEmpty && topics.isNotEmpty) {
      showSearchResults();
    }
  }

  void removeSearchResults() {
    if (overlayEntry != null) {
      overlayEntry?.remove();
      overlayEntry = null;
    }
  }

  void showSearchResults() {
    if (!Get.context!.mounted) return;
    
    removeSearchResults();

    final context = Get.context!;
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    // 获取搜索框的全局位置和大小
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    
    final position = box.localToGlobal(Offset.zero);
    final size = box.size;

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: position.dy + size.height + 5,
        left: position.dx,
        width: size.width,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12.w),
          color: Theme.of(context).cardColor,
          child: Obx(() {
            if (topics.isEmpty) {
              return Container(
                padding: EdgeInsets.symmetric(vertical: 16.w),
                child: Center(
                  child: Text(
                    searchError.value.isNotEmpty 
                        ? searchError.value 
                        : '没有找到相关内容',
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 14.w,
                    ),
                  ),
                ),
              );
            }
            
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: 380.w,
              ),
              child: ListView.builder(
                padding: EdgeInsets.symmetric(vertical: 8.w),
                shrinkWrap: true,
                itemCount: topics.length,
                itemBuilder: (context, index) {
                  final topic = topics[index];
                  return InkWell(
                    onTap: () {
                      clearSearch();
                      removeSearchResults();
                      searchFocusNode.unfocus();
                      Get.toNamed(Routes.TOPIC_DETAIL, arguments: topic.id);
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.w,
                        vertical: 8.w,
                      ),
                      child: Text(
                        topic.title ?? '',
                        style: TextStyle(
                          fontSize: 14.w,
                          color: Theme.of(context).textTheme.bodyMedium?.color,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                },
              ),
            );
          }),
        ),
      ),
    );

    overlay.insert(overlayEntry!);
  }

  // 搜索帖子
  Future<List<Topic>> searchTopics(String filter) async {
    if (filter.isEmpty) {
      topics.clear();
      searchResult.value = null;
      return [];
    }

    try {
      isSearching.value = true;
      searchError.value = '';

      // 调用搜索 API
      final result = await _apiService.search(
        query: '$filter order:latest',
        page: 1,
      );

      // 保存搜索结果
      searchResult.value = result;
      
      // 更新话题列表
      if (result.topics.isNotEmpty) {
        topics.assignAll(result.topics);
      } else {
        topics.clear();
      }

      return result.topics;
    } catch (e, s ) {
      l.e('搜索失败: $e  $s');
      searchError.value = '搜索失败，请重试';
      topics.clear();
      return [];
    } finally {
      isSearching.value = false;
    }
  }

  // 清除搜索结果
  void clearSearch() {
    topics.clear();
    searchResult.value = null;
    searchError.value = '';
  }

  // 加载更多搜索结果
  Future<void> loadMoreSearchResults() async {
    if (searchResult.value == null || 
        !searchResult.value!.groupedSearchResult.moreFullPageResults ||
        isSearching.value) {
      return;
    }

    try {
      isSearching.value = true;
      
      // 计算下一页
      final currentPage = (topics.length / 20).ceil() + 1;
      
      // 获取当前搜索词
      final currentTerm = searchResult.value!.groupedSearchResult.term;
      
      // 加载下一页
      final result = await _apiService.search(
        query: currentTerm,
        page: currentPage,
      );

      // 添加新的话题
      if (result.topics.isNotEmpty) {
        topics.addAll(result.topics);
      }

      // 更新搜索结果
      searchResult.value = result;
    } catch (e) {
      l.e('加载更多搜索结果失败: $e');
      searchError.value = '加载更多失败，请重试';
    } finally {
      isSearching.value = false;
    }
  }

  // 更新搜索框焦点状态
  void updateSearchFocus(bool isFocused) {
    isSearchFocused.value = isFocused;
  }
}
