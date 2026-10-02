package com.example.hbhost;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

public final class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView view = new TextView(this);
        view.setText("ARM64 HoneyBoard parser host is running");
        view.setTextSize(20.0f);
        view.setPadding(48, 48, 48, 48);
        setContentView(view);
    }
}
