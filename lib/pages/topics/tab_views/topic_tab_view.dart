import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../utils/log.dart';
import '../../../widgets/li_do_refresh.dart';
import '../../../widgets/state_view.dart';
import '../../../widgets/topic_item.dart';
import 'topic_tab_controller.dart';

class TopicTabView extends StatefulWidget {
  final String path;

  const TopicTabView({Key? key, required this.path}) : super(key: key);

  @override
  State<TopicTabView> createState() => _TopicTabViewState();
}

class _TopicTabViewState extends State<TopicTabView>
    with AutomaticKeepAliveClientMixin {
  late TopicTabController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.find<TopicTabController>(tag: widget.path);
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Obx(() {
      final content = LiDoSmartRefresher(
        controller: controller.refreshController,
        onRefresh: controller.onRefresh,
        onLoading: controller.loadMore,
        enablePullDown: true,
        enablePullUp: true,
        child: CustomScrollView(
          physics: const ClampingScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final topic = controller.topics[index];
                    return TopicItem(
                      topic: topic,
                      avatarUrl: controller.getLatestPosterAvatar(topic),
                      nickName: controller.getNickName(topic),
                      onTap: () => controller.toTopicDetail(topic.id),
                      onDoNotDisturb: (topic) {
                        l.d('免打扰 ： ${topic.id}');
                      },
                    );
                  },
                  childCount: controller.topics.length,
                ),
              ),
            ),
          ],
        ),
      );

      return StateView(
        state: _getViewState(),
        errorMessage: controller.errorMessage.value,
        onRetry: controller.fetchTopics,
        child: content,
      );
    });
  }

  ViewState _getViewState() {
    if (controller.isLoading.value) {
      return ViewState.loading;
    }
    if (controller.hasError.value) {
      return ViewState.error;
    }
    if (controller.topics.isEmpty) {
      return ViewState.empty;
    }
    return ViewState.content;
  }
}
