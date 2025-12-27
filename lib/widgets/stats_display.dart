import 'package:flutter/material.dart';

class StatsDisplay extends StatelessWidget {
  final int total;
  final int completed;
  final int active;
  final int failed;
  final int pending;
  final bool isCompact;

  const StatsDisplay({
    super.key,
    required this.total,
    required this.completed,
    required this.active,
    required this.failed,
    required this.pending,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        color: Colors.grey.shade100,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildCompactStat('Total: $total', Colors.blue),
            _buildCompactStat('✓ $completed', Colors.green),
            _buildCompactStat('⚙️ $active', Colors.orange),
            _buildCompactStat('✗ $failed', Colors.red),
            _buildCompactStat('🕐 $pending', Colors.grey),
          ],
        ),
      );
    }

    return Wrap(
      alignment: WrapAlignment.spaceAround,
      spacing: 12.0,
      runSpacing: 12.0,
      children: [
        _buildDetailStat('Total', total.toString(), Colors.blue),
        _buildDetailStat('✓ Completed', completed.toString(), Colors.green),
        _buildDetailStat('⚙️ Active', active.toString(), Colors.orange),
        _buildDetailStat('✗ Failed', failed.toString(), Colors.red),
        _buildDetailStat('🕐 Pending', pending.toString(), Colors.grey),
      ],
    );
  }

  Widget _buildCompactStat(String text, Color color) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: color,
      ),
    );
  }

  Widget _buildDetailStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}
